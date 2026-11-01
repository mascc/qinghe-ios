package com.pornshop.player.data

import android.util.Base64
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * CryptoJS.AES.decrypt(ciphertext, passphrase) 的 OpenSSL 兼容实现：
 * Salted__ + 8 字节 salt，EVP_BytesToKey(MD5, 1 轮) 推出 AES-256 key 与 IV。
 */
object OpenSslAes {
    private val saltedMagic = "Salted__".toByteArray(Charsets.US_ASCII)

    fun decryptToString(base64Cipher: String, passphrase: String): String {
        val raw = Base64.decode(base64Cipher.trim(), Base64.DEFAULT)
        if (raw.size < 16 || !raw.copyOfRange(0, 8).contentEquals(saltedMagic)) {
            throw IllegalStateException("响应不是 OpenSSL Salted AES")
        }
        val salt = raw.copyOfRange(8, 16)
        val cipherBytes = raw.copyOfRange(16, raw.size)
        val (key, iv) = evpBytesToKey(passphrase.toByteArray(Charsets.UTF_8), salt)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            IvParameterSpec(iv),
        )
        return String(cipher.doFinal(cipherBytes), Charsets.UTF_8)
    }

    private fun evpBytesToKey(password: ByteArray, salt: ByteArray): Pair<ByteArray, ByteArray> {
        val md = MessageDigest.getInstance("MD5")
        val needed = 48
        val out = ByteArray(needed)
        var filled = 0
        var prev = ByteArray(0)
        while (filled < needed) {
            md.reset()
            md.update(prev)
            md.update(password)
            md.update(salt)
            prev = md.digest()
            val copy = minOf(prev.size, needed - filled)
            prev.copyInto(out, destinationOffset = filled, endIndex = copy)
            filled += copy
        }
        return out.copyOfRange(0, 32) to out.copyOfRange(32, 48)
    }
}
