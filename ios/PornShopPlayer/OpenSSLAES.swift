import CommonCrypto
import Foundation

enum OpenSSLAESError: LocalizedError {
    case invalidEnvelope
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope: "响应不是 OpenSSL Salted AES"
        case .decryptionFailed: "响应解密失败"
        }
    }
}

enum OpenSSLAES {
    private static let magic = Array("Salted__".utf8)

    /// 91porna 的公开网页对部分 CDN 海报采用固定的 AES-128-CBC 包装。
    /// 这只返回经过 PKCS#7 验证的原始字节；调用处仍会用图片魔数和 UIKit
    /// 解码再作一次校验，普通（未包装）图片则不经过这里。
    static func decryptPorna91Poster(_ cipherText: Data) -> Data? {
        let key = Array("f5d965df75336270".utf8)
        let iv = Array("97b60394abc2fbe1".utf8)
        guard !cipherText.isEmpty, cipherText.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }

        var output = [UInt8](repeating: 0, count: cipherText.count + kCCBlockSizeAES128)
        var used = 0
        let status = cipherText.withUnsafeBytes { cipherBytes in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, cipherBytes.baseAddress, cipherText.count,
                &output, output.count, &used
            )
        }
        guard status == kCCSuccess, used > 0 else { return nil }
        return Data(output.prefix(used))
    }

    static func decryptToString(_ cipherText: String, passphrase: String) throws -> String {
        guard let raw = Data(base64Encoded: cipherText.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count >= 16,
              Array(raw.prefix(8)) == magic else {
            throw OpenSSLAESError.invalidEnvelope
        }
        let salt = Array(raw[8..<16])
        let material = evpBytesToKey(password: Array(passphrase.utf8), salt: salt, length: 48)
        let key = Array(material[0..<32])
        let iv = Array(material[32..<48])
        let body = Array(raw[16...])
        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var used = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, body, body.count, &output, output.count, &used
        )
        guard status == kCCSuccess else { throw OpenSSLAESError.decryptionFailed }
        guard let text = String(bytes: output.prefix(used), encoding: .utf8) else {
            throw OpenSSLAESError.decryptionFailed
        }
        return text
    }

    private static func evpBytesToKey(password: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        var output: [UInt8] = []
        var previous: [UInt8] = []
        while output.count < length {
            let value = previous + password + salt
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            value.withUnsafeBytes { bytes in
                _ = CC_MD5(bytes.baseAddress, CC_LONG(value.count), &digest)
            }
            previous = digest
            output += digest
        }
        return Array(output.prefix(length))
    }
}
