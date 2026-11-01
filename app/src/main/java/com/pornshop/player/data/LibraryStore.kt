package com.pornshop.player.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** 收藏和观看足迹写在本机，进程被系统回收后还在。 */
class LibraryStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun loadFavorites(): List<VideoItem> = decode(prefs.getString(KEY_FAV, null))

    fun loadHistory(): List<VideoItem> = decode(prefs.getString(KEY_HISTORY, null))

    fun save(favorites: List<VideoItem>, history: List<VideoItem>) {
        prefs.edit()
            .putString(KEY_FAV, encode(favorites))
            .putString(KEY_HISTORY, encode(history))
            .apply()
    }

    private fun encode(items: List<VideoItem>): String {
        val arr = JSONArray()
        items.forEach { item ->
            arr.put(
                JSONObject().apply {
                    put("id", item.id)
                    put("title", item.title)
                    put("cover", item.cover ?: JSONObject.NULL)
                    put("duration", item.duration ?: JSONObject.NULL)
                    put("views", item.views ?: JSONObject.NULL)
                    put("user", item.user ?: JSONObject.NULL)
                    put("vip", item.vip)
                    put("timeLine", item.timeLine ?: JSONObject.NULL)
                    put("videoType", item.videoType ?: JSONObject.NULL)
                    put("tags", JSONArray(item.tags))
                    put("site", item.site)
                },
            )
        }
        return arr.toString()
    }

    private fun decode(raw: String?): List<VideoItem> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    if (id.isBlank()) continue
                    val tags = o.optJSONArray("tags")
                    add(
                        VideoItem(
                            id = id,
                            title = o.optString("title").ifBlank { "视频 $id" },
                            cover = o.optString("cover").takeIf { it.startsWith("http") },
                            duration = o.optString("duration").takeIf { it.isNotBlank() && it != "null" },
                            views = o.optString("views").takeIf { it.isNotBlank() && it != "null" },
                            user = o.optString("user").takeIf { it.isNotBlank() && it != "null" },
                            vip = o.optBoolean("vip"),
                            timeLine = o.optString("timeLine").takeIf { it.isNotBlank() && it != "null" },
                            videoType = o.optString("videoType").takeIf { it.isNotBlank() && it != "null" },
                            tags = if (tags == null) {
                                emptyList()
                            } else {
                                (0 until tags.length()).map { tags.optString(it) }.filter { it.isNotBlank() }
                            },
                            site = o.optString("site").ifBlank { Sites.PORNSHOP },
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private companion object {
        const val PREFS = "pornshop_library"
        const val KEY_FAV = "favorites"
        const val KEY_HISTORY = "history"
    }
}
