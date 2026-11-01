package com.pornshop.player.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** 下载任务元数据。视频文件在应用专属目录，卸载后一起消失。 */
class DownloadStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(): List<DownloadTask> = decode(prefs.getString(KEY, null))

    fun save(tasks: List<DownloadTask>) {
        prefs.edit().putString(KEY, encode(tasks)).commit()
    }

    private fun encode(tasks: List<DownloadTask>): String {
        val arr = JSONArray()
        tasks.forEach { task ->
            arr.put(
                JSONObject().apply {
                    put("id", task.id)
                    put("title", task.title)
                    put("cover", task.cover ?: JSONObject.NULL)
                    put("duration", task.duration ?: JSONObject.NULL)
                    put("views", task.views ?: JSONObject.NULL)
                    put("user", task.user ?: JSONObject.NULL)
                    put("vip", task.vip)
                    put("timeLine", task.timeLine ?: JSONObject.NULL)
                    put("videoType", task.videoType ?: JSONObject.NULL)
                    put("tags", JSONArray(task.tags))
                    put("site", task.site)
                    put("remoteUrl", task.remoteUrl)
                    put("localUrl", task.localUrl ?: JSONObject.NULL)
                    put("status", task.status.name)
                    put("done", task.done)
                    put("total", task.total)
                    put("bytes", task.bytes)
                    put("error", task.error ?: JSONObject.NULL)
                    put("updatedAt", task.updatedAt)
                },
            )
        }
        return arr.toString()
    }

    private fun decode(raw: String?): List<DownloadTask> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    if (id.isBlank()) continue
                    val tags = o.optJSONArray("tags")
                    val status = runCatching { DownloadStatus.valueOf(o.optString("status")) }
                        .getOrDefault(DownloadStatus.PAUSED)
                    add(
                        DownloadTask(
                            id = id,
                            title = o.optString("title").ifBlank { "视频 $id" },
                            cover = o.optString("cover").takeIf { it.startsWith("http") },
                            duration = text(o, "duration"),
                            views = text(o, "views"),
                            user = text(o, "user"),
                            vip = o.optBoolean("vip"),
                            timeLine = text(o, "timeLine"),
                            videoType = text(o, "videoType"),
                            tags = if (tags == null) {
                                emptyList()
                            } else {
                                (0 until tags.length()).map { tags.optString(it) }.filter { it.isNotBlank() }
                            },
                            site = o.optString("site").ifBlank { Sites.PORNSHOP },
                            remoteUrl = o.optString("remoteUrl"),
                            localUrl = text(o, "localUrl"),
                            status = status,
                            done = o.optInt("done"),
                            total = o.optInt("total"),
                            bytes = o.optLong("bytes"),
                            error = text(o, "error"),
                            updatedAt = o.optLong("updatedAt"),
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun text(o: JSONObject, key: String): String? {
        val s = o.optString(key)
        return s.takeIf { it.isNotBlank() && it != "null" }
    }

    private companion object {
        const val PREFS = "pornshop_downloads"
        const val KEY = "tasks"
    }
}
