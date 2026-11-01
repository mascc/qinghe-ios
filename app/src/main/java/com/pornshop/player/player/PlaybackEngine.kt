package com.pornshop.player.player

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import com.pornshop.player.data.PornShopRepository
import okhttp3.OkHttpClient

/**
 * 全屏和小窗共用同一个播放器。在线分片走磁盘缓存；本地 m3u8 直接读下载目录。
 */
@UnstableApi
class PlaybackEngine(context: Context) {
    private val appContext = context.applicationContext
    var player: ExoPlayer? = null
        private set
    private var boundKey: String? = null

    fun prepare(
        itemId: String,
        url: String,
        nonce: Int,
        client: OkHttpClient,
        pageOrigin: String = PornShopRepository.PAGE_ORIGIN,
    ): ExoPlayer {
        val key = "$itemId#$nonce#$url#$pageOrigin"
        val existing = player
        if (existing != null && boundKey == key) return existing
        player = null
        boundKey = null
        existing?.release()
        val created = buildPlayer(itemId, url, client, pageOrigin)
        player = created
        boundKey = key
        return created
    }

    fun release() {
        player?.release()
        player = null
        boundKey = null
    }

    private fun buildPlayer(
        itemId: String,
        url: String,
        client: OkHttpClient,
        pageOrigin: String,
    ): ExoPlayer {
        val local = url.startsWith("file:")
        val httpFactory = OkHttpDataSource.Factory(client)
            .setUserAgent(USER_AGENT)
            .setDefaultRequestProperties(
                mapOf(
                    "Referer" to pageOrigin,
                    "Origin" to pageOrigin.trimEnd('/'),
                ),
            )
        val upstream = DefaultDataSource.Factory(appContext, httpFactory)
        val sourceFactory = if (local) {
            DefaultDataSource.Factory(appContext)
        } else {
            CacheDataSource.Factory()
                .setCache(StreamCache.get(appContext))
                .setUpstreamDataSourceFactory(upstream)
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        }
        val mediaItem = MediaItem.Builder()
            .setUri(url)
            .setMediaId(itemId)
            .setCustomCacheKey("${pageOrigin.trimEnd('/')}:$itemId")
            .build()
        val isHls = url.contains(".m3u8", ignoreCase = true)
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(15_000, 50_000, 1_200, 2_500)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        val renderers = DefaultRenderersFactory(appContext).setEnableDecoderFallback(true)
        val errorPolicy = DefaultLoadErrorHandlingPolicy(4)
        return ExoPlayer.Builder(appContext)
            .setRenderersFactory(renderers)
            .setLoadControl(loadControl)
            .setHandleAudioBecomingNoisy(true)
            .build()
            .apply {
                videoScalingMode = C.VIDEO_SCALING_MODE_SCALE_TO_FIT
                if (isHls) {
                    setMediaSource(
                        HlsMediaSource.Factory(sourceFactory)
                            .setAllowChunklessPreparation(true)
                            .setLoadErrorHandlingPolicy(errorPolicy)
                            .createMediaSource(mediaItem),
                    )
                } else {
                    setMediaSource(
                        DefaultMediaSourceFactory(sourceFactory)
                            .setLoadErrorHandlingPolicy(errorPolicy)
                            .createMediaSource(mediaItem),
                    )
                }
                playWhenReady = true
                prepare()
            }
    }

    private companion object {
        const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
    }
}
