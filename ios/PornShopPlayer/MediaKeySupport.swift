import CommonCrypto
import Foundation

/// AVFoundation 播放 HLS 时会自己去取 `#EXT-X-KEY` 指向的密钥。
/// 海角的密钥要现场按站点规则合成、抖音的 `encryption.key` 要用 RSA 解包，
/// 因此把「这份清单的密钥该怎么算」随 Playable 一起交给本地桥接层，
/// 由桥接层在密钥请求上完成还原后再交给播放器。
enum HLSKeyPlan: Hashable, Sendable {
    case haijiao(versions: [String])
    case douyinRSA

    /// 离线任务只保存字符串，重启后仍能按同样的方式还原密钥。
    var rawValue: String {
        switch self {
        case .haijiao(let versions):
            "haijiao:" + versions.joined(separator: ",")
        case .douyinRSA:
            "douyin"
        }
    }

    static func from(rawValue: String?) -> HLSKeyPlan? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        if rawValue == "douyin" { return .douyinRSA }
        guard rawValue.hasPrefix("haijiao:") else { return nil }
        let versions = rawValue.dropFirst("haijiao:".count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return .haijiao(versions: versions.isEmpty ? ["1", "2"] : versions)
    }
}

/// 海角 HLS 播放清单里「能离线复现」的那部分规则。
///
/// 清单旁的 `.jpg` 是同目录的 base64 素材；候选密钥先原样试，首片校验不过再做
/// `jquery_key`：`key[i] = key[i] xor jpg[i % jpg.count]`。首片按 AES-128-CBC、
/// 无填充解开后第 0 与第 188 字节必须都是 TS 同步字节 0x47，否则候选不能当播放密钥。
enum HaijiaoKeys {
    static let fullMinSegments = 60
    static let fullMinSeconds = 120.0
    /// 长清单可达数千分片，完整读取后才能登记全部轮换密钥。
    static let maxPlaylistBytes = 2 * 1024 * 1024

    struct KeyProbe {
        let keyURI: String
        let iv: Data
        let segment: String
    }

    struct Media {
        let keyURI: String?
        let iv: Data?
        let firstSegment: String?
        let durationSeconds: Double
        let segmentCount: Int
        let probes: [KeyProbe]

        /// 预览清单分片很少；达到任一上限即视为完整清单。
        var isFull: Bool {
            segmentCount >= HaijiaoKeys.fullMinSegments || durationSeconds >= HaijiaoKeys.fullMinSeconds
        }
    }

    /// 清单和密钥只在海角自己的主机族上成立。
    static func pageLooksHaijiao(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        let suffixes = ["haijiao.com", "aido8.icu", "daga88n.com", "ririri.me"]
        return suffixes.contains { host == $0 || host.hasSuffix("." + $0) } || host.contains(".vj")
    }

    static func isRemoteKey(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        let path = lower.split(separator: "?", maxSplits: 1).first.map(String.init) ?? lower
        return path.contains(".key") && !path.contains(".m3u8")
    }

    /// 与站点脚本一致：原地址、`.keyv{kv}`、`.key{kv}`、`.keyv`。
    /// 默认再覆盖 kversion 1 和 2，站点换版后不至于立刻失效。
    static func candidateURLs(keyURI: String, versions: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for version in versions {
            for value in keyCandidates(keyURI: keyURI, kVersion: version) where seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }

    static func keyCandidates(keyURI: String, kVersion: String) -> [String] {
        let version = kVersion.isEmpty ? "1" : kVersion
        var seen = Set<String>()
        return [
            keyURI,
            replaceKeySuffix(keyURI, suffix: ".keyv\(version)"),
            replaceKeySuffix(keyURI, suffix: ".key\(version)"),
            replaceKeySuffix(keyURI, suffix: ".keyv"),
        ].filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 清单地址换成同目录的 `.jpg` 素材地址。
    static func jpgURL(listURL: String) -> String {
        guard let range = listURL.range(of: #"\.m3u8(\?[^#]*)?$"#, options: .regularExpression) else { return listURL }
        return listURL.replacingCharacters(in: range, with: ".jpg")
    }

    static func decodeJpgMaterial(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return data
    }

    static func jqueryKey(raw: Data, material: Data) -> Data {
        guard !raw.isEmpty, !material.isEmpty else { return raw }
        let bytes = [UInt8](raw)
        let mask = [UInt8](material)
        var output = [UInt8](repeating: 0, count: bytes.count)
        for index in bytes.indices {
            output[index] = bytes[index] ^ mask[index % mask.count]
        }
        return Data(output)
    }

    /// 清单写了 IV 就用它；没写时按 HLS 用首片媒体序号（序号 0 等于 32 位零 IV）。
    static func keyOK(key: Data, iv: Data, segment: Data) -> Bool {
        guard key.count == 16, iv.count == 16, segment.count >= 376 else { return false }
        let length = segment.count - segment.count % 16
        guard length >= 376, let plain = aesDecryptNoPadding(segment.prefix(length), key: key, iv: iv) else { return false }
        let bytes = [UInt8](plain)
        guard bytes.count > 188 else { return false }
        return bytes[0] == 0x47 && bytes[188] == 0x47
    }

    /// 先原样密钥，再 `jquery_key` 合成。都不过校验就返回 nil。
    static func selectKey(candidates: [Data], material: Data?, iv: Data?, segment: Data?) -> Data? {
        guard let iv, let segment else { return nil }
        for raw in candidates where raw.count == 16 {
            if keyOK(key: raw, iv: iv, segment: segment) { return raw }
            if let material, !material.isEmpty {
                let mixed = jqueryKey(raw: raw, material: material)
                if mixed.count == 16, keyOK(key: mixed, iv: iv, segment: segment) { return mixed }
            }
        }
        return nil
    }

    static func parse(text: String, baseURL: String) throws -> Media {
        var keyURI: String?
        var iv: Data?
        var sequence: Int64 = 0
        var duration = 0.0
        var count = 0
        var first: String?
        var firstSequence: Int64 = 0
        var sawSegment = false
        var probes: [String: KeyProbe] = [:]
        var order: [String] = []

        let body = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                let value = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                sequence = Int64(value.trimmingCharacters(in: .whitespaces)) ?? sequence
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                duration += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY") {
                if line.contains("METHOD=NONE") {
                    keyURI = nil
                    iv = nil
                } else {
                    guard line.contains("METHOD=AES-128") else {
                        throw RepositoryError.invalidResponse("暂不支持此视频的加密方式")
                    }
                    if let raw = capture(#"URI="([^"]+)""#, in: line), !raw.isEmpty {
                        keyURI = resolve(baseURL, raw)
                    }
                    if let hex = capture(#"IV=0x([0-9a-fA-F]+)"#, in: line) {
                        iv = hexIV(hex)
                    }
                }
            } else if line.isEmpty || line.hasPrefix("#") {
                continue
            } else {
                count += 1
                let segment = resolve(baseURL, line)
                if !sawSegment {
                    first = segment
                    firstSequence = sequence
                    sawSegment = true
                }
                if let keyURI {
                    if probes[keyURI] == nil {
                        probes[keyURI] = KeyProbe(keyURI: keyURI, iv: iv ?? sequenceIV(sequence), segment: segment)
                        order.append(keyURI)
                    }
                }
                sequence += 1
            }
        }
        let probe = order.first.flatMap { probes[$0] }
        let resolvedIV = probe?.iv ?? (first != nil ? sequenceIV(firstSequence) : nil)
        return Media(
            keyURI: probe?.keyURI,
            iv: resolvedIV,
            firstSegment: probe?.segment ?? first,
            durationSeconds: duration,
            segmentCount: count,
            probes: order.compactMap { probes[$0] }
        )
    }

    /// 把清单里所有 AES-128 的密钥地址替换成本地桥接地址。
    static func retargetAESKey(playlist: String, keyURL: String) -> String {
        let safe = keyURL.replacingOccurrences(of: "\"", with: "")
        let hadNewline = playlist.hasSuffix("\n")
        let body = playlist.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let value = String(line)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("#EXT-X-KEY"),
                      !value.contains("METHOD=NONE"),
                      value.contains("URI=") else { return value }
                return replaceURI(in: value, with: safe)
            }
            .joined(separator: "\n")
        return hadNewline && !body.hasSuffix("\n") ? body + "\n" : body
    }

    static func replaceURI(in line: String, with value: String) -> String {
        guard let range = line.range(of: #"URI=(?:"[^"]*"|'[^']*'|[^,\s]+)"#, options: .regularExpression) else {
            return line
        }
        return line.replacingCharacters(in: range, with: "URI=\"\(value)\"")
    }

    static func sequenceIV(_ sequence: Int64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(bitPattern: sequence)
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        return Data(bytes)
    }

    static func hexIV(_ hex: String) -> Data? {
        var value = hex
        if value.count % 2 == 1 { value = "0" + value }
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.count == 16 ? Data(bytes) : nil
    }

    static func resolve(_ base: String, _ reference: String) -> String {
        let clean = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("http://") || clean.hasPrefix("https://") { return clean }
        guard let baseURL = URL(string: base), let url = URL(string: clean, relativeTo: baseURL) else { return clean }
        return url.absoluteURL.absoluteString
    }

    private static func replaceKeySuffix(_ keyURI: String, suffix: String) -> String {
        guard let range = keyURI.range(of: #"\.key(?=\?|$)"#, options: .regularExpression) else { return keyURI }
        return String(keyURI[..<range.lowerBound]) + suffix + String(keyURI[range.upperBound...])
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    static func aesDecryptNoPadding(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 16, iv.count == 16, !data.isEmpty, data.count % 16 == 0 else { return nil }
        var output = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count, &output, output.count, &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        return Data(output.prefix(moved))
    }
}

/// 按海角的规则把一个 `#EXT-X-KEY` 地址还原成真正的 16 字节播放密钥。
///
/// 顺序与站点脚本一致：取首个分片的头部做校验样本，逐个试候选密钥地址，
/// 原样不过再做 `jquery_key` 合成；素材地址和分片都来自这份清单本身。
struct HaijiaoKeyResolver: Sendable {
    static let segmentProbeBytes = 384
    static let maxMaterialBytes = 512 * 1024

    let origin: String
    let userAgent: String

    func key(keyURL: URL, iv: Data, segmentURL: URL?, playlistURL: URL, versions: [String]) async throws -> Data {
        guard let segmentURL else { throw RepositoryError.invalidResponse("无法读取视频分片，请重试") }
        let segment = try await load(url: segmentURL, maxBytes: Self.segmentProbeBytes, ranged: true)
        guard let segment, segment.count >= 376 else {
            throw RepositoryError.invalidResponse("无法读取视频分片，请重试")
        }
        var material: Data?
        var materialLoaded = false
        for candidate in HaijiaoKeys.candidateURLs(keyURI: keyURL.absoluteString, versions: versions) {
            guard let url = URL(string: candidate) else { continue }
            guard let bytes = try await load(url: url, maxBytes: 64, ranged: false), bytes.count == 16 else { continue }
            if HaijiaoKeys.keyOK(key: bytes, iv: iv, segment: segment) { return bytes }
            if !materialLoaded {
                materialLoaded = true
                if let materialURL = URL(string: HaijiaoKeys.jpgURL(listURL: playlistURL.absoluteString)),
                   let text = try await load(url: materialURL, maxBytes: Self.maxMaterialBytes, ranged: false) {
                    material = HaijiaoKeys.decodeJpgMaterial(String(decoding: text, as: UTF8.self))
                }
            }
            if let resolved = HaijiaoKeys.selectKey(candidates: [bytes], material: material, iv: iv, segment: segment) {
                return resolved
            }
        }
        throw RepositoryError.invalidResponse("无法获取可用的播放密钥，请重试")
    }

    /// 返回最多 `maxBytes` 个字节。分片校验只需要头部，所以先用 Range 请求，
    /// 服务端不支持 Range 时再退回整段读取（仍截断到上限）。
    func load(url: URL, maxBytes: Int, ranged: Bool) async throws -> Data? {
        if let data = try await loadOnce(url: url, maxBytes: maxBytes, ranged: ranged) { return data }
        guard ranged else { return nil }
        return try await loadOnce(url: url, maxBytes: maxBytes, ranged: false)
    }

    private func loadOnce(url: URL, maxBytes: Int, ranged: Bool) async throws -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(origin, forHTTPHeaderField: "Referer")
        request.setValue(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if ranged { request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
        return data.count > maxBytes ? Data(data.prefix(maxBytes)) : data
    }
}
