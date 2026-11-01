package com.pornshop.player.player

import android.content.Context
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/** 在线播放分片缓存。离线文件另存在下载目录，不会被这里淘汰。 */
@UnstableApi
object StreamCache {
    private val ref = AtomicReference<SimpleCache?>(null)

    fun get(context: Context): SimpleCache {
        ref.get()?.let { return it }
        synchronized(this) {
            ref.get()?.let { return it }
            val dir = File(context.applicationContext.cacheDir, "pornshop-exo").apply { mkdirs() }
            val cache = SimpleCache(
                dir,
                LeastRecentlyUsedCacheEvictor(256L * 1024L * 1024L),
                StandaloneDatabaseProvider(context.applicationContext),
            )
            ref.set(cache)
            return cache
        }
    }
}
