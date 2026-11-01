import Foundation
import Network

/// A loopback-only HLS bridge for the adapted video sources.
///
/// AVFoundation accepts an ordinary HTTP HLS source but does not reliably
/// preserve page Referer/custom CDN headers for every source. This small
/// in-process server therefore presents ordinary local HTTP HLS to AVPlayer,
/// while it fetches only the selected stream over HTTPS. It keeps the existing
/// rou.video PNG transport unpacking support and adds the two key schemes the
/// upstream clients implement: 海角's synthesized AES key and 抖音's RSA-wrapped
/// `encryption.key`. The listener binds to 127.0.0.1 only; it is not exposed to a LAN.
final class RouHLSHTTPProxy: @unchecked Sendable {
    /// 清单请求专用的站点头（例如 91porna 的 CDN 清单校验头）。
    private let playlistHeaders: [String: String]
    /// 分片与密钥请求的头。抖音要求自己的 User-Agent，其余来源留空。
    private let assetHeaders: [String: String]
    private let keyPlan: HLSKeyPlan?
    private let origin: String
    private let queue = DispatchQueue(label: "site.loopback-proxy")
    private let session: URLSession
    private var listener: NWListener?
    private var port: UInt16?

    init(
        origin: String,
        playlistHeaders: [String: String] = [:],
        assetHeaders: [String: String] = [:],
        keyPlan: HLSKeyPlan? = nil
    ) {
        self.origin = origin
        self.playlistHeaders = playlistHeaders
        self.assetHeaders = assetHeaders
        self.keyPlan = keyPlan
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit { stop() }

    func start() async throws {
        if port != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let parameters = NWParameters.tcp
                // Bind the bridge exclusively to the device itself. The HLS
                // player is the only client and uses 127.0.0.1 below.
                parameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(IPv4Address.loopback), port: .any
                )
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let self, let port = listener.port else {
                            listener.stateUpdateHandler = nil
                            continuation.resume(throwing: RepositoryError.invalidResponse("本地播放器启动失败"))
                            return
                        }
                        self.port = port.rawValue
                        listener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        session.invalidateAndCancel()
    }

    func playlistURL(for remoteURL: URL) -> URL? { proxyURL(for: remoteURL) }

    private func proxyURL(for remoteURL: URL) -> URL? {
        guard let port else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/hls"
        components.queryItems = [URLQueryItem(name: "url", value: remoteURL.absoluteString)]
        return components.url
    }

    /// 密钥请求走单独的本地路径：它需要原清单地址、IV 与首个分片才能还原密钥。
    private func keyURL(remoteKey: URL, iv: Data?, segment: URL?, playlist: URL) -> URL? {
        guard let port else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/key"
        var items = [
            URLQueryItem(name: "url", value: remoteKey.absoluteString),
            URLQueryItem(name: "list", value: playlist.absoluteString),
        ]
        if let iv { items.append(URLQueryItem(name: "iv", value: Self.hex(iv))) }
        if let segment { items.append(URLQueryItem(name: "seg", value: segment.absoluteString)) }
        components.queryItems = items
        return components.url
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, error == nil else {
                connection.cancel()
                return
            }
            Task { [weak self] in
                let response = await self?.response(for: data) ?? Self.errorResponse(status: 502, message: "Proxy unavailable")
                self?.send(response, on: connection)
            }
        }
    }

    private func response(for requestData: Data) async -> Data {
        guard let requestText = String(data: requestData, encoding: .utf8),
              let firstLine = requestText.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET "),
              let target = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).dropFirst().first,
              let components = URLComponents(string: "http://localhost\(target)") else {
            return Self.errorResponse(status: 400, message: "Bad request")
        }
        let query = { (name: String) -> String? in
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        if components.path == "/key" {
            return await keyResponse(query: query, requestText: requestText)
        }
        guard components.path == "/hls",
              let remoteText = query("url"),
              let remoteURL = URL(string: remoteText),
              ["https", "http"].contains(remoteURL.scheme?.lowercased() ?? "") else {
            return Self.errorResponse(status: 400, message: "Bad request")
        }

        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 30
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(origin, forHTTPHeaderField: "Referer")
            request.setValue(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
            assetHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            // 91porna 只在清单请求上校验这几个公开 CDN 头；分片与密钥主机
            // 不接受它们，所以和下载器一样按扩展名限定。
            if remoteURL.path.lowercased().contains(".m3u8") {
                playlistHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            }
            let (wireData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return Self.errorResponse(status: 502, message: "Upstream media unavailable")
            }
            let payload = try RouHLSPayload.unwrapIfNeeded(wireData)
            let output: Data
            let contentType: String
            if RouHLSPayload.isPlaylist(payload) {
                output = rewritePlaylist(payload, baseURL: http.url ?? remoteURL)
                contentType = "application/vnd.apple.mpegurl"
            } else {
                output = payload
                contentType = "video/mp2t"
            }
            return Self.httpResponse(data: output, contentType: contentType, rangeHeader: Self.header(named: "Range", in: requestText))
        } catch {
            return Self.errorResponse(status: 502, message: "Media decode failed")
        }
    }

    // MARK: - 密钥还原

    private func keyResponse(query: (String) -> String?, requestText: String) async -> Data {
        guard let plan = keyPlan,
              let remoteText = query("url"),
              let remote = URL(string: remoteText),
              let listText = query("list"),
              let playlist = URL(string: listText) else {
            return Self.errorResponse(status: 400, message: "Bad key request")
        }
        let iv = query("iv").flatMap(Self.data(hex:))
        let segment = query("seg").flatMap { URL(string: $0) }

        do {
            let key: Data?
            switch plan {
            case .douyinRSA:
                key = try await douyinKey(remote: remote)
            case .haijiao(let versions):
                guard let iv, let segment else {
                    return Self.errorResponse(status: 502, message: "Key context missing")
                }
                let resolver = HaijiaoKeyResolver(
                    origin: origin,
                    userAgent: Self.userAgent
                )
                key = try await resolver.key(
                    keyURL: remote, iv: iv, segmentURL: segment, playlistURL: playlist, versions: versions
                )
            }
            guard let key, key.count == 16 else {
                return Self.errorResponse(status: 502, message: "Key unavailable")
            }
            return Self.binaryResponse(data: key)
        } catch {
            return Self.errorResponse(status: 502, message: "Key decode failed")
        }
    }

    /// 抖音的 `encryption.key` 是一个 256 字节 RSA 块。播放器只会拿到还原后的
    /// 16 字节 AES 密钥，因此这里必须取得完整块（不能带 Range）。
    private func douyinKey(remote: URL) async throws -> Data? {
        var request = URLRequest(url: remote)
        request.timeoutInterval = 25
        request.setValue(origin, forHTTPHeaderField: "Referer")
        request.setValue(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        assetHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
        return DouyinMediaKey.unwrap(data)
    }

    // MARK: - 清单改写

    private func rewritePlaylist(_ payload: Data, baseURL: URL) -> Data {
        let lines = String(decoding: payload, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let targetDuration = lines.compactMap { line -> Int? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("#EXTINF:") else { return nil }
            let raw = value.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
            return Double(raw).map { Int(ceil($0)) }
        }.max()

        var sequence: Int64 = 0
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for (index, original) in lines.enumerated() {
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                output.append(original)
                continue
            }
            if trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                let raw = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                sequence = Int64(raw.trimmingCharacters(in: .whitespaces)) ?? sequence
                output.append(original)
                continue
            }
            if trimmed.hasPrefix("#EXT-X-TARGETDURATION:"), let targetDuration {
                output.append("#EXT-X-TARGETDURATION:\(targetDuration)")
                continue
            }
            if trimmed.hasPrefix("#EXT-X-KEY"), keyPlan != nil, !trimmed.contains("METHOD=NONE") {
                output.append(rewriteKeyLine(trimmed, lines: lines, from: index + 1, baseURL: baseURL, sequence: sequence))
                continue
            }
            if trimmed.hasPrefix("#") {
                output.append(rewriteAttributeURIs(in: original, baseURL: baseURL))
                continue
            }
            guard let remote = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
                  let proxy = proxyURL(for: remote) else {
                output.append(original)
                sequence += 1
                continue
            }
            output.append(proxy.absoluteString)
            sequence += 1
        }
        return Data(output.joined(separator: "\n").utf8)
    }

    /// 一个 `#EXT-X-KEY` 覆盖它之后的全部已加密分片。还原密钥需要这份清单的地址、
    /// IV（清单没写时按媒体序号推导）与作用域内的首个分片。
    private func rewriteKeyLine(_ line: String, lines: [String], from index: Int, baseURL: URL, sequence: Int64) -> String {
        let expression = try? NSRegularExpression(pattern: #"URI=(?:"([^"]+)"|'([^']+)'|([^,\s]+))"#)
        guard let expression,
              let matchInLine = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let uriRange = Range(matchInLine.range(at: 1), in: line)
                ?? Range(matchInLine.range(at: 2), in: line)
                ?? Range(matchInLine.range(at: 3), in: line) else { return line }
        let reference = String(line[uriRange])
        guard let remoteKey = URL(string: reference, relativeTo: baseURL)?.absoluteURL else { return line }

        var segment: URL?
        for candidate in lines[index...] {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("#") { continue }
            segment = URL(string: value, relativeTo: baseURL)?.absoluteURL
            break
        }
        let iv: Data?
        if let hexRange = line.range(of: #"IV=0x([0-9a-fA-F]+)"#, options: .regularExpression) {
            let hex = line[hexRange].replacingOccurrences(of: "IV=0x", with: "")
            iv = HaijiaoKeys.hexIV(hex)
        } else if line.contains("METHOD=AES-128") {
            iv = HaijiaoKeys.sequenceIV(sequence)
        } else {
            iv = nil
        }
        guard let local = keyURL(remoteKey: remoteKey, iv: iv, segment: segment, playlist: baseURL) else { return line }
        return HaijiaoKeys.replaceURI(in: line, with: local.absoluteString)
    }

    private func rewriteAttributeURIs(in line: String, baseURL: URL) -> String {
        let expression = try? NSRegularExpression(pattern: #"URI=(?:\"([^\"]+)\"|'([^']+)'|([^,\s]+))"#)
        guard let expression else { return line }
        let matches = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
        return matches.reversed().reduce(line) { result, match in
            let reference = (1...3).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: result) else { return nil }
                return String(result[range])
            }.first
            guard let reference,
                  let remote = URL(string: reference, relativeTo: baseURL)?.absoluteURL,
                  let proxy = proxyURL(for: remote),
                  let range = Range(match.range, in: result) else { return result }
            return result.replacingCharacters(in: range, with: "URI=\"\(proxy.absoluteString)\"")
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func header(named name: String, in request: String) -> String? {
        request.components(separatedBy: "\r\n").dropFirst().first { line in
            line.lowercased().hasPrefix("\(name.lowercased()):")
        }?.split(separator: ":", maxSplits: 1).dropFirst().first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(hex: String) -> Data? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count % 2 == 1 { value = "0" + value }
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func httpResponse(data: Data, contentType: String, rangeHeader: String?) -> Data {
        let requestedStart: Int? = rangeHeader.flatMap { value in
            guard value.lowercased().hasPrefix("bytes=") else { return nil }
            return Int(value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1).first ?? "")
        }
        let start = min(max(requestedStart ?? 0, 0), data.count)
        let body = Data(data[start..<data.count])
        let isPartial = requestedStart != nil
        let status = isPartial ? "206 Partial Content" : "200 OK"
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if isPartial { headers += "Content-Range: bytes \(start)-\(max(start, data.count - 1))/\(data.count)\r\n" }
        headers += "\r\n"
        return Data(headers.utf8) + body
    }

    private static func binaryResponse(data: Data) -> Data {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + data
    }

    private static func errorResponse(status: Int, message: String) -> Data {
        let body = Data(message.utf8)
        return Data("HTTP/1.1 \(status) Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
}
