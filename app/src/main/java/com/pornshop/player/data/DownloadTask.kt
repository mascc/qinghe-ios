package com.pornshop.player.data

enum class DownloadStatus {
    QUEUED,
    RUNNING,
    PAUSED,
    COMPLETED,
    FAILED,
}

data class DownloadTask(
    val id: String,
    val title: String,
    val cover: String?,
    val duration: String?,
    val views: String?,
    val user: String?,
    val vip: Boolean,
    val timeLine: String?,
    val videoType: String?,
    val tags: List<String> = emptyList(),
    val site: String = Sites.PORNSHOP,
    val remoteUrl: String,
    val localUrl: String?,
    val status: DownloadStatus,
    val done: Int = 0,
    val total: Int = 0,
    val bytes: Long = 0L,
    val error: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val percent: Int
        get() = if (total <= 0) 0 else ((done * 100L) / total).toInt().coerceIn(0, 100)

    fun toVideoItem(): VideoItem = VideoItem(
        id = id,
        title = title.ifBlank { "视频 $id" },
        cover = cover,
        duration = duration,
        views = views,
        user = user,
        vip = vip,
        timeLine = timeLine,
        videoType = videoType,
        tags = tags,
        site = site,
    )

    fun progressLabel(): String = when (status) {
        DownloadStatus.QUEUED -> "排队中"
        DownloadStatus.RUNNING -> if (total > 0) "下载中 $percent%" else "正在解析播放列表…"
        DownloadStatus.PAUSED -> if (total > 0) "已暂停 $percent%" else "已暂停"
        DownloadStatus.COMPLETED -> "已完成 · 可离线播放"
        DownloadStatus.FAILED -> error?.takeIf { it.isNotBlank() } ?: "下载失败"
    }
}
