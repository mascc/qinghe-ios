package com.pornshop.player.data

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * pornshop.one / 好色TV（hstv.fun）共用的 H5 客户端。
 *
 * 所有业务请求 POST 到线路 `/js`，正文里的 url 才是真正的接口，app 字段区分片库。
 * 响应字段 r 用口令 AES 解密。列表每页 24 条。好色 TV 换线路时 url_search 带 `?server=`。
 */
class PornShopRepository {
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()
    private val ua =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    @Volatile
    var site: Sites.Profile = Sites.byId(Sites.PORNSHOP)
        private set

    @Volatile
    private var preferredHost: String = HOSTS.first()

    @Volatile
    private var hotPages: Int? = null

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(true)
        .build()

    fun buildVideoClient(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .followRedirects(true)
        .build()

    fun useSite(profile: Sites.Profile) {
        if (site.id != profile.id) hotPages = null
        site = profile
    }

    fun fetchHome(section: String): ListPage {
        val profile = site
        val items = parseVideos(callArray("/sevenVideos?page=1&type=$section", profile), profile.id)
        return ListPage(items = items, page = 1, totalPage = 1, total = items.size)
    }

    fun listVideos(type: String, page: Int): ListPage {
        val profile = site
        val p = page.coerceAtLeast(1)
        val items = parseVideos(callArray("/sevenVideos?page=$p&type=$type", profile), profile.id)
        val known = if (type == "hot" || type == "recent") ensureHotPages() else null
        val full = items.size >= Catalog.pageSizeFor(type)
        val totalPage = when {
            !full -> p
            known != null -> known.coerceAtLeast(p)
            else -> p + 1
        }
        return ListPage(
            items = items,
            page = p,
            totalPage = totalPage.coerceAtLeast(1),
            total = if (known != null) known * Catalog.PAGE_SIZE else items.size,
            openEnded = known == null && full,
        )
    }

    fun searchAggregated(
        keyword: String,
        page: Int,
        category: String,
        timeInDays: String,
        views: String,
        durationMins: String,
        sortBy: String,
        keywordLogic: String,
    ): ListPage {
        val parts = ArrayList<ListPage>(Sites.all.size)
        var last: Exception? = null
        for (profile in Sites.all) {
            try {
                parts += search(
                    keyword, page, category, timeInDays, views, durationMins, sortBy, keywordLogic, profile,
                )
            } catch (e: Exception) {
                last = e
            }
        }
        if (parts.isEmpty()) throw last ?: IllegalStateException("聚合搜索失败")
        val items = parts.flatMap { it.items }.distinctBy { it.site to it.id }
        val more = parts.any { it.openEnded }
        val p = page.coerceAtLeast(1)
        return ListPage(
            items = items,
            page = p,
            totalPage = if (more) p + 1 else p,
            total = items.size,
            openEnded = more,
        )
    }

    fun search(
        keyword: String,
        page: Int,
        category: String,
        timeInDays: String,
        views: String,
        durationMins: String,
        sortBy: String,
        keywordLogic: String,
        profile: Sites.Profile = site,
    ): ListPage {
        val wd = keyword.trim()
        require(wd.isNotEmpty()) { "搜索关键词不能为空" }
        val p = page.coerceAtLeast(1)
        val items = parseVideos(
            callArray("/searchSevenVideos", profile) {
                put("page", p)
                put("keywords", wd)
                put("filterCategory", category.ifBlank { "all" })
                put("filterTimeInDays", timeInDays.ifBlank { "all" })
                put("filterViews", views.ifBlank { "all" })
                put("filterDurationInMins", durationMins.ifBlank { "all" })
                put("sortBy", sortBy.ifBlank { "time" })
                put("keywordLogic", keywordLogic.ifBlank { "or" })
            },
            profile.id,
        )
        val more = items.size >= Catalog.PAGE_SIZE
        return ListPage(
            items = items,
            page = p,
            totalPage = if (more) p + 1 else p,
            total = items.size,
            openEnded = more,
        )
    }

    fun currentHost(): String = preferredHost

    fun cycleHost(): String {
        val idx = HOSTS.indexOf(preferredHost)
        val next = HOSTS[(idx + 1).mod(HOSTS.size)]
        preferredHost = next
        return next
    }

    fun resolvePlayable(item: VideoItem, line: String? = null): Playable {
        val profile = Sites.byId(item.site)
        val chosen = line?.takeIf { key -> profile.lines.any { it.key == key } }
            ?: profile.lines.firstOrNull()?.key
        val obj = callObject("/sevenVideos/${item.id}", profile) {
            put("userId", JSONObject.NULL)
            put("url_search", if (chosen.isNullOrBlank()) "" else "?server=$chosen")
            put("token", "ufd")
        }
        val streams = obj.optJSONArray("m3u8s")
        val allUrls = buildList {
            if (streams != null) {
                for (i in 0 until streams.length()) {
                    val s = streams.optString(i).trim()
                    if (s.startsWith("http") && s !in this) add(s)
                }
            }
            val single = obj.optString("m3u8").trim()
            if (single.startsWith("http") && single !in this) add(single)
        }
        val url = allUrls.firstOrNull() ?: throw IllegalStateException("没有可播放的地址")
        val title = obj.optString("title").ifBlank { item.displayTitle }
        val meta = readMeta(obj)
        return Playable(
            id = item.id,
            title = title,
            playUrl = url,
            streamUrls = allUrls,
            cover = firstThumb(obj) ?: item.cover,
            duration = obj.optString("durationStr").ifBlank { item.duration },
            user = text(obj, "user") ?: item.user,
            views = meta.views ?: item.views,
            timeLine = meta.timeLine ?: item.timeLine,
            tags = meta.tags.ifEmpty { item.tags },
            activeHost = preferredHost.removePrefix("https://"),
            lineKey = chosen.orEmpty(),
            lines = profile.lines,
            pageOrigin = profile.pageOrigin,
            site = profile.id,
        )
    }

    private fun ensureHotPages(): Int {
        hotPages?.let { return it }
        val global = callObject("/retrieveGlobal", site)
        val count = global.optInt("tvideosReadyCount", Catalog.PAGE_SIZE)
        val pages = (count + Catalog.PAGE_SIZE - 1) / Catalog.PAGE_SIZE
        hotPages = pages.coerceAtLeast(1)
        return hotPages!!
    }

    private fun parseVideos(arr: JSONArray, siteId: String): List<VideoItem> {
        val out = ArrayList<VideoItem>(arr.length())
        val seen = HashSet<String>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val item = parseVideo(o, siteId) ?: continue
            if (seen.add(item.id)) out += item
        }
        return out
    }

    private fun parseVideo(o: JSONObject, siteId: String): VideoItem? {
        val id = text(o, "id") ?: text(o, "vId") ?: return null
        val title = text(o, "title") ?: text(o, "title_en") ?: "视频 $id"
        val meta = readMeta(o)
        return VideoItem(
            id = id,
            title = title,
            cover = firstThumb(o),
            duration = text(o, "durationStr"),
            views = meta.views,
            user = text(o, "user"),
            vip = asBool(o, "vip"),
            timeLine = meta.timeLine,
            videoType = text(o, "videoType"),
            tags = meta.tags,
            site = siteId,
        )
    }

    /**
     * 列表里的 tags 是「18 分钟前 | 25232次播放」这种统计文案，不是标签。
     * 真正的关键词在 keywords_gem。
     */
    private fun readMeta(o: JSONObject): ItemMeta {
        val stats = text(o, "tags")
        val fromStats = stats
            ?.substringBefore("|")
            ?.trim()
            ?.takeIf { it.isNotBlank() && (it.contains("前") || it.contains("刚刚") || it.contains("ago", true)) }
        val timeField = text(o, "time")?.takeIf { value ->
            value.any { !it.isDigit() } && !value.contains("播放")
        }
        val keywords = when (val gem = if (o.has("keywords_gem") && !o.isNull("keywords_gem")) o.get("keywords_gem") else null) {
            is JSONArray -> (0 until gem.length()).map { gem.optString(it) }
            is String -> gem.split(',', '，', '|', '、')
            else -> emptyList()
        }
        return ItemMeta(
            timeLine = fromStats ?: timeField,
            views = when (val v = if (o.has("views") && !o.isNull("views")) o.opt("views") else null) {
                null -> null
                is Number -> v.toLong().toString()
                else -> v.toString().takeIf { it.isNotBlank() && it != "null" }
            },
            tags = keywords
                .map { it.trim().removePrefix("#") }
                .filter { token ->
                    token.length in 1..24 &&
                        !token.contains("播放") &&
                        !token.contains("分钟") &&
                        !token.all { it.isDigit() }
                }
                .distinct(),
        )
    }

    private fun firstThumb(o: JSONObject): String? {
        val arr = o.optJSONArray("thumbnails")
            ?: o.optJSONArray("thumbNails")
            ?: o.optJSONArray("covers")
        if (arr != null) {
            for (i in 0 until arr.length()) {
                normalizeMediaUrl(arr.optString(i))?.let { return it }
            }
        }
        listOf("thumbnails", "thumb", "cover", "pic", "image", "poster").forEach { key ->
            normalizeMediaUrl(text(o, key))?.let { return it }
        }
        return null
    }

    private fun normalizeMediaUrl(raw: String?): String? {
        val s = raw?.trim().orEmpty()
        if (s.isEmpty() || s == "null") return null
        return when {
            s.startsWith("https://") || s.startsWith("http://") -> s
            s.startsWith("//") -> "https:$s"
            else -> null
        }
    }

    private fun text(o: JSONObject, key: String): String? {
        if (!o.has(key) || o.isNull(key)) return null
        val v = o.opt(key) ?: return null
        if (v is JSONArray || v is JSONObject) return null
        val s = v.toString().trim()
        return s.takeIf { it.isNotBlank() && it != "null" }
    }

    private fun asBool(o: JSONObject, key: String): Boolean {
        if (!o.has(key) || o.isNull(key)) return false
        return when (val v = o.opt(key)) {
            is Boolean -> v
            is Number -> v.toInt() != 0
            is String -> v == "1" || v.equals("true", ignoreCase = true)
            else -> false
        }
    }

    private fun callArray(
        urlPath: String,
        profile: Sites.Profile = site,
        fill: JSONObject.() -> Unit = {},
    ): JSONArray {
        val value = call(urlPath, profile, fill)
        if (value is JSONArray) return value
        throw IllegalStateException("列表响应不是数组")
    }

    private fun callObject(
        urlPath: String,
        profile: Sites.Profile = site,
        fill: JSONObject.() -> Unit = {},
    ): JSONObject {
        val value = call(urlPath, profile, fill)
        if (value is JSONObject) return value
        throw IllegalStateException("详情响应不是对象")
    }

    private fun call(
        urlPath: String,
        profile: Sites.Profile = site,
        fill: JSONObject.() -> Unit = {},
    ): Any {
        val body = JSONObject().apply {
            put("deviceInfo", JSONObject())
            put("app", profile.appName)
            put("version", API_VERSION)
            put("isStandalone", false)
            put("theLink", "novaluenull")
            put("uuid", "novalue")
            fill()
            put("url", urlPath)
        }
        val payload = body.toString()
        val order = buildList {
            add(preferredHost)
            HOSTS.forEach { if (it != preferredHost) add(it) }
        }
        var last: Exception? = null
        for (host in order) {
            try {
                val raw = post(host, payload, profile)
                val envelope = JSONObject(raw)
                val cipher = envelope.optString("r")
                if (cipher.isBlank()) throw IllegalStateException("响应缺少 r")
                val plain = OpenSslAes.decryptToString(cipher, AES_PASSPHRASE).trim()
                preferredHost = host
                return when {
                    plain.startsWith("[") -> JSONArray(plain)
                    plain.startsWith("{") -> JSONObject(plain)
                    else -> throw IllegalStateException("解密结果不是 JSON")
                }
            } catch (e: Exception) {
                last = e
            }
        }
        throw last ?: IllegalStateException("所有线路均失败")
    }

    private fun post(host: String, payload: String, profile: Sites.Profile): String {
        val req = Request.Builder()
            .url("$host/js")
            .header("User-Agent", ua)
            .header("Accept", "application/json,text/plain,*/*")
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer undefined")
            .header("Origin", profile.pageOrigin.trimEnd('/'))
            .header("Referer", profile.pageOrigin)
            .post(payload.toRequestBody(jsonMedia))
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw IllegalStateException("HTTP ${resp.code} $host")
            }
            if (text.isBlank()) throw IllegalStateException("空响应 $host")
            return text
        }
    }

    private data class ItemMeta(
        val timeLine: String?,
        val views: String?,
        val tags: List<String>,
    )

    companion object {
        const val API_VERSION = "260901"
        const val AES_PASSPHRASE = "xxx"
        const val PAGE_ORIGIN = "https://pornshop.one/"

        val HOSTS = listOf(
            "https://v2.cdn199.com",
            "https://v2.kekecdn.net",
            "https://v2.luchu.org",
            "https://v2.madou.ws",
            "https://v2.papapa.biz",
            "https://v2.tianmtv.com",
            "https://v2.xiaoshuo.info",
            "https://v2.xiaoshuo.la",
        )
    }
}
