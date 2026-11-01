import AVFoundation
import Compression
import Foundation

/// rou.video 目前将其公开 HLS 清单和 TS 分片放进 PNG 的私有 `roUd` chunk。
/// 网站自己的浏览器播放器在收到响应后做相同的解包，再交给 HLS 引擎。本加载器
/// 只适配这个公开的传输封装；得到的仍是普通 m3u8 与 MPEG-TS 数据。
final class RouHLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "rouhls"

    private let origin: String
    private let session: URLSession

    init(origin: String) {
        self.origin = origin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        super.init()
    }

    static func assetURL(for remoteURL: URL) -> URL {
        proxiedURL(for: remoteURL, localPath: "/playlist.m3u8")
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, let remoteURL = Self.remoteURL(from: url) else {
            loadingRequest.finishLoading(with: RepositoryError.invalidResponse("肉视频媒体地址无效"))
            return false
        }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(origin, forHTTPHeaderField: "Referer")
        request.setValue(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let data, let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                loadingRequest.finishLoading(with: RepositoryError.invalidResponse("肉视频媒体请求失败"))
                return
            }
            do {
                let payload = try RouHLSPayload.unwrapIfNeeded(data)
                let responseURL = http.url ?? remoteURL
                let finalData: Data
                let contentType: String
                if RouHLSPayload.isPlaylist(payload) {
                    finalData = Self.rewritePlaylist(payload, baseURL: responseURL)
                    // AVAssetResourceLoadingContentInformationRequest expects
                    // a Uniform Type Identifier rather than a MIME string.
                    // `public.m3u-playlist` is the system UTI registered for
                    // application/vnd.apple.mpegurl / .m3u8. (The commonly
                    // seen `com.apple.mpegurl` is not a registered UTI.)
                    contentType = "public.m3u-playlist"
                } else {
                    finalData = payload
                    contentType = "public.mpeg-2-transport-stream"
                }
                self.respond(to: loadingRequest, data: finalData, contentType: contentType)
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // URLSession 的请求很短；取消后的响应会被 AVFoundation 安全地忽略。
    }

    private func respond(to request: AVAssetResourceLoadingRequest, data: Data, contentType: String) {
        if let content = request.contentInformationRequest {
            content.contentType = contentType
            content.contentLength = Int64(data.count)
            content.isByteRangeAccessSupported = true
        }
        if let dataRequest = request.dataRequest {
            let start = min(max(0, dataRequest.requestedOffset), Int64(data.count))
            if start < Int64(data.count) {
                // 对自定义 scheme 的首个 HLS 请求，AVFoundation 可能只用很短的
                // requestedLength 来嗅探类型。若按该长度截断后立即 finishLoading，
                // 它会把例如 "#E" 当作完整清单并报 -12646。这里从请求偏移处返回
                // 完整资源，保持 contentLength 与实际响应一致。
                dataRequest.respond(with: data.subdata(in: Int(start)..<data.count))
            }
        }
        request.finishLoading()
    }

    private static func rewritePlaylist(_ payload: Data, baseURL: URL) -> Data {
        let text = String(decoding: payload, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // rou.video's current manifests declare TARGETDURATION:8 while multiple
        // EXTINF entries are 8.333333 seconds. Browser HLS libraries tolerate
        // this, but AVFoundation rejects it as an invalid HLS playlist. Use a
        // valid upper bound when handing the public manifest to AVFoundation.
        let targetDuration = lines.compactMap { line -> Int? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("#EXTINF:") else { return nil }
            let raw = value.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
            guard let duration = Double(raw) else { return nil }
            return Int(ceil(duration))
        }.max()
        let rewritten = lines
            .map { line -> String in
                let original = String(line)
                let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return original }
                if trimmed.hasPrefix("#EXT-X-TARGETDURATION:"), let targetDuration {
                    return "#EXT-X-TARGETDURATION:\(targetDuration)"
                }
                if trimmed.hasPrefix("#") { return rewriteAttributeURIs(in: original, baseURL: baseURL) }
                guard let remote = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else { return original }
                return proxiedURL(for: remote, localPath: "/segment.ts").absoluteString
            }
            .joined(separator: "\n")
        return Data(rewritten.utf8)
    }

    private static func rewriteAttributeURIs(in line: String, baseURL: URL) -> String {
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
                  let range = Range(match.range, in: result) else { return result }
            let proxied = proxiedURL(for: remote, localPath: "/resource.bin").absoluteString
            return result.replacingCharacters(in: range, with: "URI=\"\(proxied)\"")
        }
    }

    private static func proxiedURL(for remoteURL: URL, localPath: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "resource"
        components.path = localPath
        components.queryItems = [URLQueryItem(name: "url", value: remoteURL.absoluteString)]
        // The components are fully specified; this fallback is unreachable in practice.
        return components.url ?? remoteURL
    }

    private static func remoteURL(from url: URL) -> URL? {
        guard url.scheme == scheme,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let remote = URL(string: value),
              ["https", "http"].contains(remote.scheme?.lowercased() ?? "") else { return nil }
        return remote
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
}

enum RouHLSPayload {
    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let maxDecodedBytes = 64 * 1024 * 1024

    static func isPlaylist(_ data: Data) -> Bool {
        String(decoding: data.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("#EXTM3U")
    }

    /// 解出网站播放器定义的 roUd chunk。普通 HLS 响应原样返回，因此也可安全复用
    /// 于下载管理器的所有现有来源。
    static func unwrapIfNeeded(_ data: Data) throws -> Data {
        guard data.starts(with: pngSignature) else { return data }
        var offset = pngSignature.count
        while offset + 12 <= data.count {
            let length = try uint32(in: data, at: offset)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(length)
            guard payloadEnd + 4 <= data.count else { throw RepositoryError.invalidResponse("肉视频媒体容器不完整") }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if type == "roUd" {
                guard payloadStart < payloadEnd else { throw RepositoryError.invalidResponse("肉视频媒体容器为空") }
                let flags = data[payloadStart]
                let body = Data(data[(payloadStart + 1)..<payloadEnd])
                return flags & 1 == 1 ? try inflate(body) : body
            }
            offset = payloadEnd + 4
        }
        throw RepositoryError.invalidResponse("肉视频媒体容器缺少播放数据")
    }

    private static func uint32(in data: Data, at offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw RepositoryError.invalidResponse("肉视频媒体容器不完整") }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func inflate(_ compressed: Data) throws -> Data {
        guard !compressed.isEmpty else { return Data() }
        // `roUd` carries a RFC 1950 zlib wrapper (CMF/FLG + Adler-32). Apple's
        // COMPRESSION_ZLIB decoder consumes the underlying RFC 1951 DEFLATE
        // stream; passing the wrapper through returns non-zero garbage instead
        // of reporting an error. Strip a valid zlib wrapper before decoding.
        let deflate: Data
        if compressed.count > 6,
           compressed[0] & 0x0F == 8,
           ((Int(compressed[0]) << 8) | Int(compressed[1])) % 31 == 0 {
            deflate = Data(compressed.dropFirst(2).dropLast(4))
        } else {
            deflate = compressed
        }
        var capacity = max(64 * 1024, compressed.count * 4)
        while capacity <= maxDecodedBytes {
            var output = Data(count: capacity)
            let count = deflate.withUnsafeBytes { sourceBuffer in
                output.withUnsafeMutableBytes { destinationBuffer in
                    guard let input = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let destination = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        destination, capacity, input, deflate.count, nil, COMPRESSION_ZLIB
                    )
                }
            }
            if count > 0 {
                output.count = count
                return output
            }
            capacity *= 2
        }
        throw RepositoryError.invalidResponse("肉视频媒体解包失败")
    }
}
