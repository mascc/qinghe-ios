import Foundation
import Security

/// 抖音 HLS 的 `encryption.key` 不是裸密钥：它是被 RSA 包过的 16 字节 AES 密钥。
/// 播放/下载层只需要判断「这个 URL 是不是抖音的密钥」，再把 256 字节块解包成裸密钥。
/// 上游两把私钥对应两个发号渠道，都试一遍才能覆盖全部片子。
enum DouyinMediaKey {
    /// 密钥 URL 也必须来自这条线路域名才算抖音的（播放地址和来源页都指向它）。
    static let lineHost = "ecsvnp1.cn1-hongkong.aliyuncs.com"
    static let keyFileName = "encryption.key"
    /// AES-128 的密钥长度。
    static let bareKeyBytes = 16
    /// RSA-2048 的一个块正好 256 字节；超过这个长度的文件不是密钥包。
    static let wrappedBlockBytes = 256

    static func isKeyURL(_ url: URL, origin: String?) -> Bool {
        let name = url.path.split(separator: "/", omittingEmptySubsequences: true).last.map { String($0) } ?? ""
        guard name.caseInsensitiveCompare(keyFileName) == .orderedSame else { return false }
        guard let origin, let host = URL(string: origin)?.host else { return false }
        return host.caseInsensitiveCompare(lineHost) == .orderedSame
    }

    /// 旧版本已经下载好的分片里可能直接存的是裸密钥，长度 16 就原样返回，
    /// 不要拿去当 RSA 块再解一次。
    static func unwrap(_ raw: Data) -> Data? {
        if raw.count == bareKeyBytes { return raw }
        guard raw.count == wrappedBlockBytes else { return nil }
        for key in RSAKeyStore.shared.keys {
            var error: Unmanaged<CFError>?
            guard let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA256, raw as CFData, &error) else {
                continue
            }
            let decoded = plain as Data
            if decoded.count == bareKeyBytes { return decoded }
        }
        return nil
    }
}

/// SecKey 本身不是 Sendable，但这里的数组只在 init 里建一次、之后只读；
/// 用 @unchecked Sendable 把这层只读共享包起来，免得每次取密钥都重建两把 RSA 私钥。
private final class RSAKeyStore: @unchecked Sendable {
    static let shared = RSAKeyStore()

    let keys: [SecKey]

    init() {
        var built: [SecKey] = []
        for encoded in Self.keyTexts {
            if let key = Self.makeKey(encoded) { built.append(key) }
        }
        keys = built
    }

    private static func makeKey(_ encoded: String) -> SecKey? {
        guard let der = Data(base64Encoded: encoded),
              let pkcs1 = pkcs1Bytes(Array(der)) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error)
    }

    /// 常量是 PKCS#8（PrivateKeyInfo），SecKeyCreateWithData 只吃内层 PKCS#1，
    /// 所以按 DER 走一遍：SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING key }。
    private static func pkcs1Bytes(_ der: [UInt8]) -> [UInt8]? {
        guard let outer = element(der, at: 0), outer.tag == 0x30,
              let version = element(der, at: outer.contentStart), version.tag == 0x02,
              let algorithm = element(der, at: version.next), algorithm.tag == 0x30,
              let key = element(der, at: algorithm.next), key.tag == 0x04,
              key.contentEnd <= outer.contentEnd else { return nil }
        return Array(der[key.contentStart..<key.contentEnd])
    }

    private struct Element {
        let tag: UInt8
        let contentStart: Int
        let contentEnd: Int
        var next: Int { contentEnd }
    }

    private static func element(_ der: [UInt8], at offset: Int) -> Element? {
        guard offset >= 0, offset + 2 <= der.count else { return nil }
        let tag = der[offset]
        var cursor = offset + 1
        var length = Int(der[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            // 长度字段最多 4 字节，再多就不是这两把 2048 位私钥该有的形状。
            guard count >= 1, count <= 4, cursor + count <= der.count else { return nil }
            length = 0
            for index in 0..<count {
                length = (length << 8) | Int(der[cursor + index])
            }
            cursor += count
        }
        let end = cursor + length
        guard end >= cursor, end <= der.count else { return nil }
        return Element(tag: tag, contentStart: cursor, contentEnd: end)
    }

    // 上游随客户端下发的两把渠道私钥，逐字节照抄。
    private static let keyTexts: [String] = [
        "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",
    ]
}
