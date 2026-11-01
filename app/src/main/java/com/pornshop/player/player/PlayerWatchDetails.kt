package com.pornshop.player.player

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.SyncAlt
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.pornshop.player.data.Playable
import com.pornshop.player.data.VideoItem
import com.pornshop.player.ui.AppleGlassChip
import com.pornshop.player.ui.CoverImage
import com.pornshop.player.ui.AppleGlassColors
import com.pornshop.player.ui.appleGlassCard

@Composable
fun PlayerWatchDetailsSection(
    item: VideoItem,
    playable: Playable?,
    isFavorite: Boolean,
    playbackSpeed: Float,
    fitMode: Boolean,
    selectedStreamIndex: Int,
    autoPlayNext: Boolean,
    upNextItems: List<VideoItem>,
    videoWidth: Int,
    videoHeight: Int,
    onToggleFavorite: () -> Unit,
    onCycleSpeed: () -> Unit,
    onToggleFitMode: () -> Unit,
    onSelectStream: (Int) -> Unit,
    onSelectLine: (String) -> Unit,
    onSwitchHost: () -> Unit,
    onMinimizeToMiniPlayer: () -> Unit,
    onToggleAutoPlayNext: () -> Unit,
    onSelectUpNext: (VideoItem) -> Unit,
    onSearchTagOrUploader: (String) -> Unit,
    downloadLabel: String,
    downloadActive: Boolean,
    onDownload: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var descExpanded by remember(item.id) { mutableStateOf(false) }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // 1. Glass Video Title & Info Card
        item(key = "info_card") {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .appleGlassCard(shape = RoundedCornerShape(22.dp))
                    .clickable { descExpanded = !descExpanded }
                    .padding(16.dp),
            ) {
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        text = playable?.title ?: item.displayTitle,
                        color = AppleGlassColors.TextPrimary,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = if (descExpanded) 6 else 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        imageVector = if (descExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = null,
                        tint = AppleGlassColors.TextSecondary,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }

                Spacer(modifier = Modifier.height(8.dp))

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (item.vip) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(AppleGlassColors.VipGoldGradient)
                                .padding(horizontal = 7.dp, vertical = 2.dp),
                        ) {
                            Text(
                                text = "VIP 已解锁",
                                color = Color.White,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                    }
                    if (videoWidth > 0 && videoHeight > 0) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(AppleGlassColors.AccentBlue.copy(alpha = 0.12f))
                                .padding(horizontal = 7.dp, vertical = 2.dp),
                        ) {
                            Text(
                                text = "${videoWidth}×${videoHeight} HD",
                                color = AppleGlassColors.AccentBlue,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                    Text(
                        text = listOfNotNull(
                            item.formattedViews,
                            playable?.timeLine ?: item.timeLine,
                            playable?.duration ?: item.duration,
                        ).joinToString(" · "),
                        color = AppleGlassColors.TextSecondary,
                        fontSize = 12.sp,
                    )
                }

                AnimatedVisibility(visible = descExpanded) {
                    Column(modifier = Modifier.padding(top = 10.dp)) {
                        Text(
                            text = "视频 ID: ${item.id}",
                            color = AppleGlassColors.TextSecondary,
                            fontSize = 12.sp,
                        )
                        val tags = playable?.tags?.ifEmpty { item.tags } ?: item.tags
                        if (tags.isNotEmpty()) {
                            Spacer(modifier = Modifier.height(8.dp))
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                tags.forEach { tag ->
                                    AppleGlassChip(
                                        label = "#$tag",
                                        selected = false,
                                        onClick = { onSearchTagOrUploader(tag) },
                                    )
                                }
                            }
                        }
                    }
                }

                Spacer(modifier = Modifier.height(12.dp))

                // Channel / Uploader Bar
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.clickable {
                            onSearchTagOrUploader(playable?.user ?: item.uploaderName)
                        },
                    ) {
                        Box(
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape)
                                .background(AppleGlassColors.AccentGradient),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = (playable?.user ?: item.uploaderName).take(1).uppercase(),
                                color = Color.White,
                                fontWeight = FontWeight.Bold,
                                fontSize = 15.sp,
                            )
                        }
                        Spacer(modifier = Modifier.width(10.dp))
                        Column {
                            Text(
                                text = playable?.user ?: item.uploaderName,
                                color = AppleGlassColors.TextPrimary,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 14.sp,
                            )
                            Text(
                                text = "点击搜索该创作者更多作品",
                                color = AppleGlassColors.TextTertiary,
                                fontSize = 11.sp,
                            )
                        }
                    }

                    AppleGlassChip(
                        label = if (isFavorite) "已收藏" else "收藏视频",
                        selected = isFavorite,
                        leadingIcon = if (isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                        onClick = onToggleFavorite,
                    )
                }
            }
        }

        // Horizontal glass action pills
        item(key = "action_bar") {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                GlassActionPill(
                    icon = Icons.Default.Download,
                    label = downloadLabel,
                    active = downloadActive,
                    onClick = onDownload,
                )
                GlassActionPill(
                    icon = Icons.Default.Speed,
                    label = "倍速 ${String.format("%.2gx", playbackSpeed)}",
                    active = playbackSpeed != 1.0f,
                    onClick = onCycleSpeed,
                )
                GlassActionPill(
                    icon = Icons.Default.AspectRatio,
                    label = if (fitMode) "画面: 适应" else "画面: 铺满",
                    active = !fitMode,
                    onClick = onToggleFitMode,
                )
                GlassActionPill(
                    icon = Icons.Default.SyncAlt,
                    label = "换线重试",
                    active = false,
                    onClick = onSwitchHost,
                )
                GlassActionPill(
                    icon = Icons.Default.PictureInPictureAlt,
                    label = "小窗边看边搜",
                    active = false,
                    onClick = onMinimizeToMiniPlayer,
                )
                GlassActionPill(
                    icon = Icons.Default.ContentCopy,
                    label = "复制流地址",
                    active = false,
                    onClick = {
                        val url = playable?.playUrl
                        if (!url.isNullOrBlank()) {
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("m3u8", url))
                            Toast.makeText(context, "已复制 M3U8 播放直链", Toast.LENGTH_SHORT).show()
                        }
                    },
                )
            }
        }

        val lines = playable?.lines.orEmpty()
        if (lines.size > 1) {
            item(key = "server_lines") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .appleGlassCard(shape = RoundedCornerShape(16.dp), elevation = 3.dp)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "线路",
                        color = AppleGlassColors.TextSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        lines.forEach { line ->
                            AppleGlassChip(
                                label = line.label,
                                selected = line.key == playable?.lineKey,
                                onClick = { onSelectLine(line.key) },
                            )
                        }
                    }
                }
            }
        }

        // 3. Multi-Stream Selector if multiple m3u8 urls exist
        val streams = playable?.streamUrls.orEmpty()
        if (streams.size > 1) {
            item(key = "stream_selector") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .appleGlassCard(shape = RoundedCornerShape(16.dp), elevation = 3.dp)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Default.GraphicEq,
                        contentDescription = null,
                        tint = AppleGlassColors.AccentPink,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = "多源流切换：",
                        color = AppleGlassColors.TextSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        streams.indices.forEach { idx ->
                            AppleGlassChip(
                                label = "源线路 ${idx + 1}",
                                selected = idx == selectedStreamIndex,
                                onClick = { onSelectStream(idx) },
                            )
                        }
                    }
                }
            }
        }

        // 4. Up Next Header + Auto-Play Switch
        item(key = "up_next_header") {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 4.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "接下来播放 · 同频推荐 (${upNextItems.size})",
                    color = AppleGlassColors.TextPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = "自动连播",
                        color = AppleGlassColors.TextSecondary,
                        fontSize = 12.sp,
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Switch(
                        checked = autoPlayNext,
                        onCheckedChange = { onToggleAutoPlayNext() },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = AppleGlassColors.AccentPink,
                        ),
                    )
                }
            }
        }

        // 5. Up Next Video Items
        items(items = upNextItems, key = { "next_${it.id}" }) { nextItem ->
            UpNextGlassRow(
                item = nextItem,
                onClick = { onSelectUpNext(nextItem) },
            )
        }
    }
}

@Composable
private fun GlassActionPill(
    icon: ImageVector,
    label: String,
    active: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .appleGlassCard(
                shape = RoundedCornerShape(999.dp),
                surfaceColor = if (active) Color(0xFFFFE4EC) else AppleGlassColors.GlassWhiteStrong,
                elevation = 4.dp,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (active) AppleGlassColors.AccentPink else AppleGlassColors.TextPrimary,
            modifier = Modifier.size(16.dp),
        )
        Spacer(modifier = Modifier.width(6.dp))
        Text(
            text = label,
            color = if (active) AppleGlassColors.AccentPink else AppleGlassColors.TextPrimary,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun UpNextGlassRow(
    item: VideoItem,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .appleGlassCard(shape = RoundedCornerShape(18.dp), elevation = 4.dp)
            .clickable(onClick = onClick)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box {
            CoverImage(
                url = item.cover,
                site = item.site,
                contentDescription = null,
                modifier = Modifier
                    .width(136.dp)
                    .aspectRatio(16f / 9f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFFE2E8F0)),
            )
            if (item.vip) {
                Text(
                    text = "VIP",
                    color = Color.White,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(5.dp)
                        .background(AppleGlassColors.AccentPink, RoundedCornerShape(5.dp))
                        .padding(horizontal = 5.dp, vertical = 1.dp),
                )
            }
            if (!item.duration.isNullOrBlank()) {
                Text(
                    text = item.duration,
                    color = Color.White,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(5.dp)
                        .background(Color.Black.copy(alpha = 0.68f), RoundedCornerShape(5.dp))
                        .padding(horizontal = 5.dp, vertical = 1.dp),
                )
            }
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.displayTitle,
                color = AppleGlassColors.TextPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(modifier = Modifier.height(5.dp))
            Text(
                text = item.metaLine,
                color = AppleGlassColors.TextSecondary,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
fun FloatingGlassMiniPlayer(
    item: VideoItem,
    playable: Playable?,
    player: ExoPlayer?,
    loading: Boolean,
    onExpand: () -> Unit,
    onPlayNext: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .appleGlassCard(
                shape = RoundedCornerShape(22.dp),
                surfaceColor = AppleGlassColors.GlassWhiteStrong,
                elevation = 14.dp,
            )
            .border(
                width = 1.2.dp,
                color = AppleGlassColors.AccentPink.copy(alpha = 0.25f),
                shape = RoundedCornerShape(22.dp),
            )
            .clickable(onClick = onExpand)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .width(86.dp)
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFF1E293B)),
        ) {
            if (player != null) {
                AndroidView(
                    factory = { ctx ->
                        PlayerView(ctx).apply {
                            useController = false
                            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                            isClickable = false
                            isFocusable = false
                            setOnTouchListener { _, _ -> false }
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                    update = { view ->
                        view.player = player
                        view.setOnTouchListener { _, event ->
                            if (event.action == android.view.MotionEvent.ACTION_UP) onExpand()
                            true
                        }
                    },
                    onRelease = { view ->
                        view.setOnTouchListener(null)
                        view.player = null
                    },
                )
            } else {
                CoverImage(
                    url = playable?.cover ?: item.cover,
                    site = playable?.site ?: item.site,
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = playable?.title ?: item.displayTitle,
                color = AppleGlassColors.TextPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = if (loading) "正在解析高清流…" else "点击展开全屏详情 · ${item.uploaderName}",
                color = AppleGlassColors.AccentPink,
                fontSize = 11.sp,
                maxLines = 1,
            )
        }
        IconButton(onClick = onPlayNext) {
            Icon(
                imageVector = Icons.Default.SkipNext,
                contentDescription = "下一集",
                tint = AppleGlassColors.TextPrimary,
            )
        }
        IconButton(onClick = onClose) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = "关闭播放",
                tint = AppleGlassColors.TextSecondary,
            )
        }
    }
}
