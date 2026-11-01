package com.pornshop.player.player

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.media.AudioManager
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BrightnessHigh
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.pornshop.player.data.Playable
import com.pornshop.player.data.VideoItem
import com.pornshop.player.ui.AppleGlassBackground
import com.pornshop.player.ui.AppleGlassColors
import com.pornshop.player.ui.hudGlassSurface
import kotlinx.coroutines.delay
import kotlin.math.abs

@UnstableApi
@Composable
fun VideoPlayerScreen(
    item: VideoItem,
    playable: Playable?,
    loading: Boolean,
    error: String?,
    selectedStreamIndex: Int,
    isFavorite: Boolean,
    autoPlayNext: Boolean,
    upNextItems: List<VideoItem>,
    player: ExoPlayer?,
    onBack: () -> Unit,
    onMinimize: () -> Unit,
    onToggleFavorite: () -> Unit,
    onSelectStream: (Int) -> Unit,
    onSelectLine: (String) -> Unit,
    onSwitchHost: () -> Unit,
    onToggleAutoPlayNext: () -> Unit,
    onPlayNext: () -> Unit,
    onPlayPrevious: () -> Unit,
    onSelectUpNext: (VideoItem) -> Unit,
    onSearchTagOrUploader: (String) -> Unit,
    downloadLabel: String,
    downloadActive: Boolean,
    onDownload: () -> Unit,
) {
    val context = LocalContext.current
    val activity = context as? Activity
    val audioManager = remember { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }

    var isFullscreen by remember { mutableStateOf(false) }
    var fitMode by remember { mutableStateOf(true) }
    var controlsVisible by remember { mutableStateOf(true) }
    var isScreenLocked by remember { mutableStateOf(false) }
    var playbackSpeed by remember(player) {
        mutableFloatStateOf(player?.playbackParameters?.speed ?: 1.0f)
    }
    var isHoldingSpeedBoost by remember { mutableStateOf(false) }
    var isMuted by remember(player) { mutableStateOf((player?.volume ?: 1f) == 0f) }

    var videoW by remember(item.id) { mutableIntStateOf(0) }
    var videoH by remember(item.id) { mutableIntStateOf(0) }
    var isPlaying by remember { mutableStateOf(true) }
    var isBuffering by remember { mutableStateOf(false) }
    var currentPosMs by remember { mutableLongStateOf(0L) }
    var durationMs by remember { mutableLongStateOf(0L) }
    var isScrubbing by remember { mutableStateOf(false) }
    var scrubPreviewMs by remember { mutableLongStateOf(0L) }
    var gestureHudText by remember { mutableStateOf<String?>(null) }

    val speedOptions = remember { listOf(0.75f, 1.0f, 1.25f, 1.5f, 2.0f) }

    // 播放器由外层持有，这里只监听。收起小窗时不能 release，否则进度会丢。
    DisposableEffect(player) {
        val p = player
        if (p == null) {
            onDispose { }
        } else {
            val listener = object : Player.Listener {
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    if (videoSize.width > 0 && videoSize.height > 0) {
                        videoW = videoSize.width
                        videoH = videoSize.height
                    }
                }

                override fun onIsPlayingChanged(playing: Boolean) {
                    isPlaying = playing
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    isBuffering = playbackState == Player.STATE_BUFFERING
                }
            }
            p.addListener(listener)
            isPlaying = p.isPlaying
            isBuffering = p.playbackState == Player.STATE_BUFFERING
            if (p.videoSize.width > 0 && p.videoSize.height > 0) {
                videoW = p.videoSize.width
                videoH = p.videoSize.height
            }
            onDispose { p.removeListener(listener) }
        }
    }

    LaunchedEffect(player, isPlaying, isScrubbing) {
        while (player != null) {
            if (!isScrubbing) {
                currentPosMs = player.currentPosition.coerceAtLeast(0L)
            }
            durationMs = player.duration.coerceAtLeast(0L)
            delay(250L)
        }
    }

    // Auto-hide controls after 3.5 seconds when playing
    LaunchedEffect(controlsVisible, isPlaying, isScrubbing) {
        if (controlsVisible && isPlaying && !isScrubbing) {
            delay(3500L)
            controlsVisible = false
        }
    }

    // Clear temporary gesture badge
    LaunchedEffect(gestureHudText) {
        if (gestureHudText != null && !isHoldingSpeedBoost && !isScrubbing) {
            delay(900L)
            gestureHudText = null
        }
    }

    // Screen orientation & system bars
    DisposableEffect(Unit) {
        val act = activity
        val controller = act?.window?.let { window ->
            WindowInsetsControllerCompat(window, window.decorView)
        }
        controller?.isAppearanceLightStatusBars = false
        onDispose {
            controller?.isAppearanceLightStatusBars = true
        }
    }

    DisposableEffect(videoW, videoH, isFullscreen) {
        val act = activity
        if (act != null) {
            if (isFullscreen) {
                act.requestedOrientation = resolveOrientation(videoW, videoH)
                applyImmersive(act, true)
            } else {
                act.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                applyImmersive(act, false)
            }
        }
        onDispose {
            if (act != null) {
                act.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                val lp = act.window.attributes
                lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                act.window.attributes = lp
                applyImmersive(act, false)
            }
        }
    }

    BackHandler {
        when {
            isScreenLocked -> isScreenLocked = false
            isFullscreen -> isFullscreen = false
            else -> onBack()
        }
    }

    AppleGlassBackground {
        Column(
            modifier = Modifier.fillMaxSize(),
        ) {
            // Top Video Player Theater Container
            Box(
                modifier = if (isFullscreen) {
                    Modifier.fillMaxSize().background(Color.Black)
                } else {
                    Modifier
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f)
                        .background(Color.Black)
                },
            ) {
                when {
                    loading || (playable == null && error == null) -> {
                        Column(
                            modifier = Modifier.align(Alignment.Center),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            CircularProgressIndicator(color = AppleGlassColors.AccentPink)
                            Spacer(modifier = Modifier.height(10.dp))
                            Text(
                                text = "正在解析高清加密流…",
                                color = Color.White.copy(alpha = 0.88f),
                                fontSize = 13.sp,
                            )
                        }
                    }
                    error != null -> {
                        Column(
                            modifier = Modifier
                                .align(Alignment.Center)
                                .padding(16.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text(
                                text = "播放加载失败：$error",
                                color = Color.White,
                                fontSize = 13.sp,
                            )
                            Spacer(modifier = Modifier.height(10.dp))
                            Box(
                                modifier = Modifier
                                    .hudGlassSurface()
                                    .clickable(onClick = onSwitchHost)
                                    .padding(horizontal = 16.dp, vertical = 8.dp),
                            ) {
                                Text("切换线路重试", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                    player != null -> {
                        AndroidView(
                            factory = { ctx ->
                                PlayerView(ctx).apply {
                                    layoutParams = FrameLayout.LayoutParams(
                                        ViewGroup.LayoutParams.MATCH_PARENT,
                                        ViewGroup.LayoutParams.MATCH_PARENT,
                                    )
                                    useController = false
                                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                                    this.player = player
                                }
                            },
                            modifier = Modifier.fillMaxSize(),
                            update = { pv ->
                                pv.player = player
                                pv.resizeMode = if (fitMode) {
                                    AspectRatioFrameLayout.RESIZE_MODE_FIT
                                } else {
                                    AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                                }
                            },
                            onRelease = { pv -> pv.player = null },
                        )

                        // Gesture Layer (Single Tap, Double Tap +-10s, Long Press 2.0x, Horizontal Scrub, Vertical Vol/Brightness)
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .pointerInput(isScreenLocked, player, playbackSpeed) {
                                    detectTapGestures(
                                        onTap = {
                                            controlsVisible = !controlsVisible
                                        },
                                        onDoubleTap = { offset ->
                                            if (isScreenLocked) return@detectTapGestures
                                            val width = size.width.toFloat().coerceAtLeast(1f)
                                            when {
                                                offset.x < width * 0.35f -> {
                                                    val target = (player.currentPosition - 10_000L).coerceAtLeast(0L)
                                                    player.seekTo(target)
                                                    currentPosMs = target
                                                    gestureHudText = "« 快退 10 秒"
                                                }
                                                offset.x > width * 0.65f -> {
                                                    val maxDur = player.duration.takeIf { it > 0 } ?: Long.MAX_VALUE
                                                    val target = (player.currentPosition + 10_000L).coerceAtMost(maxDur)
                                                    player.seekTo(target)
                                                    currentPosMs = target
                                                    gestureHudText = "快进 10 秒 »"
                                                }
                                                else -> {
                                                    if (player.isPlaying) player.pause() else player.play()
                                                }
                                            }
                                        },
                                        onLongPress = {
                                            if (isScreenLocked) return@detectTapGestures
                                            isHoldingSpeedBoost = true
                                            player.setPlaybackSpeed(2.0f)
                                            gestureHudText = "⚡ 2.0x 倍速快进中"
                                        },
                                        onPress = {
                                            tryAwaitRelease()
                                            if (isHoldingSpeedBoost) {
                                                isHoldingSpeedBoost = false
                                                player.setPlaybackSpeed(playbackSpeed)
                                                gestureHudText = null
                                            }
                                        },
                                    )
                                }
                                .pointerInput(isScreenLocked, player, durationMs) {
                                    if (isScreenLocked) return@pointerInput
                                    var dragMode = 0 // 0=none, 1=horizontal seek, 2=left brightness, 3=right volume
                                    var startPos = 0L
                                    detectDragGestures(
                                        onDragStart = { _ ->
                                            dragMode = 0
                                            startPos = player.currentPosition
                                            scrubPreviewMs = startPos
                                        },
                                        onDragEnd = {
                                            if (dragMode == 1 && isScrubbing) {
                                                player.seekTo(scrubPreviewMs)
                                                currentPosMs = scrubPreviewMs
                                            }
                                            isScrubbing = false
                                            dragMode = 0
                                        },
                                        onDragCancel = {
                                            isScrubbing = false
                                            dragMode = 0
                                        },
                                        onDrag = { change, dragAmount ->
                                            change.consume()
                                            val w = size.width.toFloat().coerceAtLeast(1f)
                                            val h = size.height.toFloat().coerceAtLeast(1f)
                                            if (dragMode == 0) {
                                                dragMode = if (abs(dragAmount.x) > abs(dragAmount.y) * 1.2f) {
                                                    1
                                                } else if (change.position.x < w * 0.5f) {
                                                    2
                                                } else {
                                                    3
                                                }
                                            }
                                            when (dragMode) {
                                                1 -> {
                                                    if (durationMs > 0L) {
                                                        isScrubbing = true
                                                        val deltaMs = ((dragAmount.x / w) * 90_000f).toLong()
                                                        scrubPreviewMs = (scrubPreviewMs + deltaMs).coerceIn(0L, durationMs)
                                                        val diffSec = (scrubPreviewMs - startPos) / 1000L
                                                        val sign = if (diffSec >= 0) "+${diffSec}s" else "${diffSec}s"
                                                        gestureHudText = "${formatMs(scrubPreviewMs)} / ${formatMs(durationMs)} ($sign)"
                                                    }
                                                }
                                                2 -> {
                                                    val win = activity?.window
                                                    if (win != null) {
                                                        val lp = win.attributes
                                                        val cur = if (lp.screenBrightness < 0f) 0.5f else lp.screenBrightness
                                                        val next = (cur - dragAmount.y / h).coerceIn(0.05f, 1.0f)
                                                        lp.screenBrightness = next
                                                        win.attributes = lp
                                                        gestureHudText = "☀ 屏幕亮度 ${(next * 100).toInt()}%"
                                                    }
                                                }
                                                3 -> {
                                                    val maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                                                    val curVol = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                                                    val step = if (-dragAmount.y > 6f) 1 else if (-dragAmount.y < -6f) -1 else 0
                                                    if (step != 0) {
                                                        val nextVol = (curVol + step).coerceIn(0, maxVol)
                                                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, nextVol, 0)
                                                        gestureHudText = "🔊 媒体音量 ${(nextVol * 100) / maxVol}%"
                                                    }
                                                }
                                            }
                                        },
                                    )
                                },
                        )
                    }
                }

                // Buffering Ring
                if (isBuffering && !loading) {
                    CircularProgressIndicator(
                        color = AppleGlassColors.AccentPink,
                        modifier = Modifier.align(Alignment.Center).size(42.dp),
                    )
                }

                // Floating Gesture / 2.0x Speed / Scrubbing Feedback Capsule
                androidx.compose.animation.AnimatedVisibility(
                    visible = gestureHudText != null,
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = 16.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .hudGlassSurface()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    ) {
                        Text(
                            text = gestureHudText.orEmpty(),
                            color = Color.White,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }

                // Custom Frosted Glass HUD Controls
                androidx.compose.animation.AnimatedVisibility(
                    visible = controlsVisible,
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(
                                Brush.verticalGradient(
                                    colors = listOf(
                                        Color.Black.copy(alpha = 0.58f),
                                        Color.Transparent,
                                        Color.Transparent,
                                        Color.Black.copy(alpha = 0.72f),
                                    ),
                                ),
                            ),
                    ) {
                        // Lock Screen Button (always accessible on left center)
                        IconButton(
                            onClick = { isScreenLocked = !isScreenLocked },
                            modifier = Modifier
                                .align(Alignment.CenterStart)
                                .padding(start = 12.dp)
                                .hudGlassSurface(shape = CircleShape)
                                .size(38.dp),
                        ) {
                            Icon(
                                imageVector = if (isScreenLocked) Icons.Default.Lock else Icons.Default.LockOpen,
                                contentDescription = "锁定屏幕",
                                tint = if (isScreenLocked) AppleGlassColors.AccentPink else Color.White,
                                modifier = Modifier.size(18.dp),
                            )
                        }

                        if (!isScreenLocked) {
                            // Top HUD Bar
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .align(Alignment.TopCenter)
                                    .then(if (!isFullscreen) Modifier.statusBarsPadding() else Modifier)
                                    .padding(horizontal = 8.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                IconButton(
                                    onClick = {
                                        if (isFullscreen) isFullscreen = false else onBack()
                                    },
                                ) {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                        contentDescription = "返回",
                                        tint = Color.White,
                                    )
                                }
                                IconButton(onClick = onMinimize) {
                                    Icon(
                                        imageVector = Icons.Default.KeyboardArrowDown,
                                        contentDescription = "小窗模式",
                                        tint = Color.White,
                                    )
                                }
                                Text(
                                    text = playable?.title ?: item.displayTitle,
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                                Box(
                                    modifier = Modifier
                                        .hudGlassSurface()
                                        .clickable { fitMode = !fitMode }
                                        .padding(horizontal = 10.dp, vertical = 4.dp),
                                ) {
                                    Text(
                                        text = if (fitMode) "适应" else "铺满",
                                        color = Color.White,
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Bold,
                                    )
                                }
                                Spacer(modifier = Modifier.width(6.dp))
                                Box(
                                    modifier = Modifier
                                        .hudGlassSurface()
                                        .clickable {
                                            val nextIdx = (speedOptions.indexOf(playbackSpeed) + 1) % speedOptions.size
                                            playbackSpeed = speedOptions[nextIdx]
                                            player?.setPlaybackSpeed(playbackSpeed)
                                        }
                                        .padding(horizontal = 10.dp, vertical = 4.dp),
                                ) {
                                    Text(
                                        text = "${String.format("%.2gx", playbackSpeed)}",
                                        color = Color.White,
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Bold,
                                    )
                                }
                            }

                            // Center Play/Pause & Seek +-10s & Prev/Next Controls
                            Row(
                                modifier = Modifier.align(Alignment.Center),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(18.dp),
                            ) {
                                IconButton(
                                    onClick = onPlayPrevious,
                                    modifier = Modifier.hudGlassSurface(CircleShape).size(40.dp),
                                ) {
                                    Icon(Icons.Default.SkipPrevious, contentDescription = "上一集", tint = Color.White)
                                }
                                IconButton(
                                    onClick = {
                                        player?.let {
                                            val target = (it.currentPosition - 10_000L).coerceAtLeast(0L)
                                            it.seekTo(target)
                                            currentPosMs = target
                                        }
                                    },
                                    modifier = Modifier.hudGlassSurface(CircleShape).size(42.dp),
                                ) {
                                    Icon(Icons.Default.Replay10, contentDescription = "快退10秒", tint = Color.White)
                                }
                                IconButton(
                                    onClick = {
                                        player?.let { if (it.isPlaying) it.pause() else it.play() }
                                    },
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(AppleGlassColors.AccentGradient)
                                        .size(54.dp),
                                ) {
                                    Icon(
                                        imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                        contentDescription = "播放/暂停",
                                        tint = Color.White,
                                        modifier = Modifier.size(28.dp),
                                    )
                                }
                                IconButton(
                                    onClick = {
                                        player?.let {
                                            val maxDur = it.duration.takeIf { d -> d > 0 } ?: Long.MAX_VALUE
                                            val target = (it.currentPosition + 10_000L).coerceAtMost(maxDur)
                                            it.seekTo(target)
                                            currentPosMs = target
                                        }
                                    },
                                    modifier = Modifier.hudGlassSurface(CircleShape).size(42.dp),
                                ) {
                                    Icon(Icons.Default.Forward10, contentDescription = "快进10秒", tint = Color.White)
                                }
                                IconButton(
                                    onClick = onPlayNext,
                                    modifier = Modifier.hudGlassSurface(CircleShape).size(40.dp),
                                ) {
                                    Icon(Icons.Default.SkipNext, contentDescription = "下一集", tint = Color.White)
                                }
                            }

                            // Bottom Scrub Bar & Time / Mute / Fullscreen Row
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .align(Alignment.BottomCenter)
                                    .padding(horizontal = 12.dp, vertical = 4.dp),
                            ) {
                                val displayPos = if (isScrubbing) scrubPreviewMs else currentPosMs
                                val progressFraction = if (durationMs > 0L) {
                                    (displayPos.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
                                } else {
                                    0f
                                }
                                Slider(
                                    value = progressFraction,
                                    onValueChange = { frac ->
                                        isScrubbing = true
                                        scrubPreviewMs = (frac * durationMs).toLong()
                                    },
                                    onValueChangeFinished = {
                                        player?.seekTo(scrubPreviewMs)
                                        currentPosMs = scrubPreviewMs
                                        isScrubbing = false
                                    },
                                    colors = SliderDefaults.colors(
                                        thumbColor = AppleGlassColors.AccentPink,
                                        activeTrackColor = AppleGlassColors.AccentPink,
                                        inactiveTrackColor = Color.White.copy(alpha = 0.32f),
                                    ),
                                    modifier = Modifier.fillMaxWidth().height(22.dp),
                                )
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text(
                                        text = "${formatMs(displayPos)} / ${formatMs(durationMs)}",
                                        color = Color.White.copy(alpha = 0.92f),
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Medium,
                                    )
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        IconButton(
                                            onClick = {
                                                isMuted = !isMuted
                                                player?.volume = if (isMuted) 0f else 1f
                                            },
                                            modifier = Modifier.size(32.dp),
                                        ) {
                                            Icon(
                                                imageVector = if (isMuted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                                contentDescription = "静音",
                                                tint = Color.White,
                                                modifier = Modifier.size(18.dp),
                                            )
                                        }
                                        IconButton(
                                            onClick = { isFullscreen = !isFullscreen },
                                            modifier = Modifier.size(32.dp),
                                        ) {
                                            Icon(
                                                imageVector = if (isFullscreen) Icons.Default.FullscreenExit else Icons.Default.Fullscreen,
                                                contentDescription = "全屏",
                                                tint = Color.White,
                                                modifier = Modifier.size(20.dp),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Below-the-Player Apple Light Glass Watch Page (visible when not in fullscreen)
            if (!isFullscreen) {
                PlayerWatchDetailsSection(
                    item = item,
                    playable = playable,
                    isFavorite = isFavorite,
                    playbackSpeed = playbackSpeed,
                    fitMode = fitMode,
                    selectedStreamIndex = selectedStreamIndex,
                    autoPlayNext = autoPlayNext,
                    upNextItems = upNextItems,
                    videoWidth = videoW,
                    videoHeight = videoH,
                    onToggleFavorite = onToggleFavorite,
                    onCycleSpeed = {
                        val nextIdx = (speedOptions.indexOf(playbackSpeed) + 1) % speedOptions.size
                        playbackSpeed = speedOptions[nextIdx]
                        player?.setPlaybackSpeed(playbackSpeed)
                    },
                    onToggleFitMode = { fitMode = !fitMode },
                    onSelectStream = onSelectStream,
                    onSelectLine = onSelectLine,
                    onSwitchHost = onSwitchHost,
                    onMinimizeToMiniPlayer = onMinimize,
                    onToggleAutoPlayNext = onToggleAutoPlayNext,
                    onSelectUpNext = onSelectUpNext,
                    onSearchTagOrUploader = onSearchTagOrUploader,
                    downloadLabel = downloadLabel,
                    downloadActive = downloadActive,
                    onDownload = onDownload,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

private fun formatMs(ms: Long): String {
    val totalSec = (ms / 1000L).coerceAtLeast(0L)
    val h = totalSec / 3600L
    val m = (totalSec % 3600L) / 60L
    val s = totalSec % 60L
    return if (h > 0) {
        String.format("%d:%02d:%02d", h, m, s)
    } else {
        String.format("%02d:%02d", m, s)
    }
}

private fun resolveOrientation(width: Int, height: Int): Int {
    if (width <= 0 || height <= 0) return ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    return if (width >= height) {
        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    } else {
        ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
    }
}

private fun applyImmersive(activity: Activity, enabled: Boolean) {
    val window = activity.window
    // 首页自己用 statusBarsPadding。这里如果把 decorFits 改回 true，
    // 系统再垫一层状态栏，返回首页顶端就会多出一条空白。
    WindowCompat.setDecorFitsSystemWindows(window, false)
    val controller = WindowInsetsControllerCompat(window, window.decorView)
    if (enabled) {
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    } else {
        controller.show(WindowInsetsCompat.Type.systemBars())
    }
}
