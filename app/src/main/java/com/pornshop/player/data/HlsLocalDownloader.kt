package com.pornshop.player.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 把 HLS 播放列表和分片落到应用目录，生成可离线播放的本地 m3u8。
 * 支持主播放列表、AES-128 密钥和 fMP4 的 EXT-X-MAP。
 */
class HlsLocalDownloader(
    private val client: OkHttpClient,
    private val pageOrigin: String = PornShopRepository.PAGE_ORIGIN,
) {
    suspend fun download(
        remoteUrl: String,
        dir: File,
        onProgress: (done: Int, total: Int) -> Unit,
    ): File {
        dir.mkdirs()
        val (mediaUrl, body) = resolveMedia(remoteUrl)
        val (playlist, assets) = rewrite(mediaUrl, body)
        if (assets.isEmpty()) throw IllegalStateException("播放列表里没有分片")
        onProgress(0, assets.size)
        var finished = 0
        coroutineScope {
            val gate = Semaphore(4)
            assets.map { asset ->
                async(Dispatchers.IO) {
                    gate.withPermit {
                        ensureActive()
                        downloadAsset(asset, dir)
                        synchronized(this@HlsLocalDownloader) {
                            finished += 1
                            onProgress(finished, assets.size)
                        }
                    }
                }
            }.awaitAll()
        }
        val index = File(dir, INDEX)
        index.writeText(playlist)
        return index
    }

    private suspend fun resolveMedia(url: String, depth: Int = 0): Pair<String, String> {
        val body = fetchText(url)
        if (depth >= 3 || !body.contains("#EXT-X-STREAM-INF")) return url to body
        val variant = pickVariant(url, body)
        return resolveMedia(variant, depth + 1)
    }

    private fun pickVariant(base: String, body: String): String {
        val lines = splitLines(body)
        var best: String? = null
        var bestScore = Long.MIN_VALUE
        var pendingScore = Long.MIN_VALUE
        var sawInf = false
        for (line in lines) {
            if (line.startsWith("#EXT-X-STREAM-INF")) {
                sawInf = true
                val bandwidth = BANDWIDTH.find(line)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
                val codecs = CODECS.find(line)?.groupValues?.get(1).orEmpty()
                val audioOnly = codecs.isNotBlank() &&
                    !codecs.contains("avc", true) &&
                    !codecs.contains("hev", true) &&
                    !codecs.contains("hvc", true) &&
                    !codecs.contains("vp9", true) &&
                    !codecs.contains("av01", true)
                pendingScore = if (audioOnly) Long.MIN_VALUE else bandwidth
            } else if (sawInf && line.isNotBlank() && !line.startsWith("#")) {
                if (pendingScore >= bestScore) {
                    bestScore = pendingScore
                    best = resolveUrl(base, line)
                }
                sawInf = false
            }
        }
        return best ?: throw IllegalStateException("没有可下载的视频流")
    }

    private fun rewrite(mediaUrl: String, body: String): Pair<String, List<Asset>> {
        val assets = mutableListOf<Asset>()
        val names = linkedMapOf<String, String>()
        val out = splitLines(body).joinToString("\n") { line ->
            when {
                line.startsWith("#EXT-X-KEY") && line.contains("METHOD=NONE") -> line
                line.startsWith("#EXT-X-KEY") -> replaceUri(line, mediaUrl, "key", "bin", names, assets)
                line.startsWith("#EXT-X-MAP") -> replaceUri(line, mediaUrl, "init", "mp4", names, assets)
                line.isBlank() || line.startsWith("#") -> line
                else -> {
                    val remote = resolveUrl(mediaUrl, line)
                    names.getOrPut(remote) {
                        val name = "seg_%05d.ts".format(assets.count { it.localName.endsWith(".ts") })
                        assets += Asset(remote, name)
                        name
                    }
                }
            }
        }
        val text = if (out.contains("#EXT-X-ENDLIST")) out else "$out\n#EXT-X-ENDLIST"
        return text.ensureSuffix("\n") to assets
    }

    private fun replaceUri(
        line: String,
        base: String,
        prefix: String,
        ext: String,
        names: LinkedHashMap<String, String>,
        assets: MutableList<Asset>,
    ): String {
        val match = URI_ATTR.find(line) ?: return line
        val raw = match.groupValues.drop(1).firstOrNull { it.isNotBlank() } ?: return line
        val remote = resolveUrl(base, raw)
        val local = names.getOrPut(remote) {
            val name = "${prefix}_%03d.$ext".format(assets.count { it.localName.startsWith(prefix) })
            assets += Asset(remote, name)
            name
        }
        return URI_TOKEN.replace(line, "URI=\"$local\"")
    }

    private suspend fun downloadAsset(asset: Asset, dir: File) {
        val target = File(dir, asset.localName)
        if (target.exists() && target.length() > 0L) return
        val part = File(dir, asset.localName + ".part")
        var last: Exception? = null
        repeat(3) { attempt ->
            try {
                fetchTo(asset.remote, part)
                if (target.exists()) target.delete()
                if (!part.renameTo(target)) {
                    part.copyTo(target, overwrite = true)
                    part.delete()
                }
                return
            } catch (e: CancellationException) {
                part.delete()
                throw e
            } catch (e: Exception) {
                last = e
                part.delete()
                delay(400L * (attempt + 1))
            }
        }
        throw last ?: IllegalStateException("分片下载失败")
    }

    private suspend fun fetchText(url: String): String {
        val bytes = fetchBytes(url)
        return bytes.toString(Charsets.UTF_8).removePrefix("\uFEFF")
    }

    private suspend fun fetchTo(url: String, dest: File) {
        dest.parentFile?.mkdirs()
        suspendCancellableCoroutine { cont ->
            val call = client.newCall(request(url))
            cont.invokeOnCancellation { call.cancel() }
            try {
                call.execute().use { resp ->
                    if (!resp.isSuccessful) {
                        throw IllegalStateException("HTTP ${resp.code}")
                    }
                    val body = resp.body ?: throw IllegalStateException("空响应")
                    FileOutputStream(dest).use { output ->
                        body.byteStream().use { input -> input.copyTo(output) }
                    }
                }
                if (cont.isActive) cont.resume(Unit)
            } catch (e: Exception) {
                if (cont.isActive) cont.resumeWithException(e)
            }
        }
    }

    private suspend fun fetchBytes(url: String): ByteArray = suspendCancellableCoroutine { cont ->
        val call = client.newCall(request(url))
        cont.invokeOnCancellation { call.cancel() }
        try {
            call.execute().use { resp ->
                if (!resp.isSuccessful) throw IllegalStateException("HTTP ${resp.code}")
                val body = resp.body ?: throw IllegalStateException("空响应")
                if (cont.isActive) cont.resume(body.bytes())
            }
        } catch (e: Exception) {
            if (cont.isActive) cont.resumeWithException(e)
        }
    }

    private fun request(url: String): Request = Request.Builder()
        .url(url)
        .header("User-Agent", UA)
        .header("Referer", pageOrigin)
        .header("Origin", pageOrigin.trimEnd('/'))
        .header("Accept", "*/*")
        .build()

    private fun splitLines(body: String): List<String> =
        body.replace("\uFEFF", "").split('\n').map { it.trimEnd('\r').trim() }

    private fun resolveUrl(base: String, ref: String): String {
        val clean = ref.trim()
        if (clean.startsWith("http://") || clean.startsWith("https://")) return clean
        return java.net.URI(base).resolve(clean).toString()
    }

    private fun String.ensureSuffix(suffix: String): String =
        if (endsWith(suffix)) this else this + suffix

    private data class Asset(val remote: String, val localName: String)

    private companion object {
        const val INDEX = "index.m3u8"
        const val UA =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
        val BANDWIDTH = Regex("""BANDWIDTH=(\d+)""")
        val CODECS = Regex("CODECS=\"([^\"]*)\"")
        val URI_ATTR = Regex("""URI=(?:"([^"]+)"|'([^']+)'|([^,\s]+))""")
        val URI_TOKEN = Regex("""URI=(?:"[^"]*"|'[^']*'|[^,\s]+)""")
    }
}
