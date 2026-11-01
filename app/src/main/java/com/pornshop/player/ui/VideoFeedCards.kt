package com.pornshop.player.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.pornshop.player.data.Catalog
import com.pornshop.player.data.Choice
import com.pornshop.player.data.Sites
import com.pornshop.player.data.VideoItem

/**
 * Widescreen 16:9 immersive card in the light glass aesthetic.
 */
@Composable
fun YouTubeFeedCard(
    item: VideoItem,
    isFavorite: Boolean,
    downloaded: Boolean,
    onClick: () -> Unit,
    onToggleFavorite: () -> Unit,
    onDownload: () -> Unit,
    onClickUploader: (String) -> Unit,
    showSite: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .appleGlassCard(shape = RoundedCornerShape(22.dp), elevation = 6.dp)
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        // 16:9 Thumbnail Container
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF1E293B)),
        ) {
            CoverImage(
                url = item.cover,
                site = item.site,
                contentDescription = item.displayTitle,
                modifier = Modifier.fillMaxSize(),
            )

            // Bottom subtle dark gradient for badge legibility
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .align(Alignment.BottomCenter)
                    .background(
                        Brush.verticalGradient(
                            colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.62f)),
                        ),
                    ),
            )

            // Top-Left VIP / HD Glass Pill
            Row(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(10.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (showSite) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color.Black.copy(alpha = 0.55f))
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                    ) {
                        Text(
                            text = Sites.byId(item.site).label,
                            color = Color.White,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
                if (item.vip) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(AppleGlassColors.VipGoldGradient)
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                    ) {
                        Text(
                            text = "VIP 尊享直连",
                            color = Color.White,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
                if (!item.videoType.isNullOrBlank()) {
                    Box(
                        modifier = Modifier
                            .hudGlassSurface(shape = RoundedCornerShape(8.dp))
                            .padding(horizontal = 7.dp, vertical = 3.dp),
                    ) {
                        Text(
                            text = item.videoType.uppercase(),
                            color = Color.White,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }

            // Center subtle glass play button
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(44.dp)
                    .hudGlassSurface(shape = CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Default.PlayArrow,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(24.dp),
                )
            }

            // Bottom-Right Duration Pill
            Row(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(10.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (downloaded) {
                    ThumbBadge("已下载")
                }
                if (!item.duration.isNullOrBlank()) {
                    ThumbBadge(item.duration)
                }
            }
        }

        Spacer(modifier = Modifier.height(11.dp))

        // Avatar, title, meta, and favorite row
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(AppleGlassColors.AccentGradient)
                    .clickable(enabled = !item.user.isNullOrBlank()) {
                        item.user?.let(onClickUploader)
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = item.uploaderName.take(1).uppercase(),
                    color = Color.White,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                )
            }

            Spacer(modifier = Modifier.width(11.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = item.displayTitle,
                    color = AppleGlassColors.TextPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    lineHeight = 20.sp,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = item.metaLine,
                    color = AppleGlassColors.TextSecondary,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            IconButton(
                onClick = onDownload,
                modifier = Modifier.size(34.dp),
            ) {
                Icon(
                    imageVector = if (downloaded) Icons.Default.DownloadDone else Icons.Default.Download,
                    contentDescription = if (downloaded) "已下载" else "下载",
                    tint = if (downloaded) AppleGlassColors.AccentEmerald else AppleGlassColors.TextTertiary,
                    modifier = Modifier.size(20.dp),
                )
            }
            IconButton(
                onClick = onToggleFavorite,
                modifier = Modifier.size(34.dp),
            ) {
                Icon(
                    imageVector = if (isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                    contentDescription = "收藏",
                    tint = if (isFavorite) AppleGlassColors.AccentPink else AppleGlassColors.TextTertiary,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

/**
 * Compact 2-Column Apple Glass Card for Grid Mode.
 */
@Composable
fun AppleGridVideoCard(
    item: VideoItem,
    isFavorite: Boolean,
    downloaded: Boolean,
    onClick: () -> Unit,
    onToggleFavorite: () -> Unit,
    onDownload: () -> Unit,
    showSite: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .appleGlassCard(shape = RoundedCornerShape(18.dp), elevation = 4.dp)
            .clickable(onClick = onClick)
            .padding(8.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFF1E293B)),
        ) {
            CoverImage(
                url = item.cover,
                site = item.site,
                contentDescription = item.displayTitle,
                modifier = Modifier.fillMaxSize(),
            )
            if (downloaded) {
                Text(
                    text = "已下载",
                    color = Color.White,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(5.dp)
                        .background(AppleGlassColors.AccentEmerald, RoundedCornerShape(5.dp))
                        .padding(horizontal = 5.dp, vertical = 1.dp),
                )
            }
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
            if (showSite) {
                Text(
                    text = Sites.byId(item.site).label,
                    color = Color.White,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(5.dp)
                        .background(Color.Black.copy(alpha = 0.68f), RoundedCornerShape(5.dp))
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
        Spacer(modifier = Modifier.height(7.dp))
        Text(
            text = item.displayTitle,
            color = AppleGlassColors.TextPrimary,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 2,
            minLines = 2,
            overflow = TextOverflow.Ellipsis,
            lineHeight = 17.sp,
        )
        Spacer(modifier = Modifier.height(4.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = item.formattedViews ?: item.uploaderName,
                color = AppleGlassColors.TextSecondary,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = if (downloaded) Icons.Default.DownloadDone else Icons.Default.Download,
                contentDescription = if (downloaded) "已下载" else "下载",
                tint = if (downloaded) AppleGlassColors.AccentEmerald else AppleGlassColors.TextTertiary,
                modifier = Modifier
                    .size(16.dp)
                    .clickable(onClick = onDownload),
            )
            Spacer(modifier = Modifier.width(8.dp))
            Icon(
                imageVector = if (isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                contentDescription = "收藏",
                tint = if (isFavorite) AppleGlassColors.AccentPink else AppleGlassColors.TextTertiary,
                modifier = Modifier
                    .size(16.dp)
                    .clickable(onClick = onToggleFavorite),
            )
        }
    }
}

@Composable
fun CoverImage(
    url: String?,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    site: String = Sites.PORNSHOP,
) {
    val context = LocalContext.current
    val origin = Sites.byId(site).pageOrigin
    AsyncImage(
        model = ImageRequest.Builder(context)
            .data(url)
            .addHeader("Referer", origin)
            .addHeader("Origin", origin.trimEnd('/'))
            .addHeader(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
            )
            .crossfade(180)
            .build(),
        contentDescription = contentDescription,
        modifier = modifier,
        contentScale = ContentScale.Crop,
        placeholder = ColorPainter(Color(0xFF1E293B)),
        error = ColorPainter(Color(0xFF334155)),
    )
}

@Composable
private fun ThumbBadge(text: String) {
    Box(
        modifier = Modifier
            .hudGlassSurface(shape = RoundedCornerShape(7.dp))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(
            text = text,
            color = Color.White,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun AggregateSearchButton(
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(16.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (enabled) 10.dp else 3.dp,
                shape = shape,
                ambientColor = AppleGlassColors.AccentPink.copy(alpha = if (enabled) 0.45f else 0.16f),
                spotColor = AppleGlassColors.AccentPink.copy(alpha = if (enabled) 0.45f else 0.16f),
            )
            .clip(shape)
            .then(
                if (enabled) Modifier.background(AppleGlassColors.AccentGradient)
                else Modifier.background(Color.White)
            )
            .border(
                width = if (enabled) 0.dp else 1.5.dp,
                color = AppleGlassColors.AccentPink,
                shape = shape,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Default.Hub,
            contentDescription = null,
            tint = if (enabled) Color.White else AppleGlassColors.AccentPink,
            modifier = Modifier.size(20.dp),
        )
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = if (enabled) "聚合搜索 · 全部平台" else "聚合搜索",
                color = if (enabled) Color.White else AppleGlassColors.AccentPink,
                fontSize = 15.sp,
                fontWeight = FontWeight.ExtraBold,
                maxLines = 1,
            )
            Text(
                text = if (enabled) "PornShop 与好色 TV 一起搜" else "当前只搜本平台，点此跨平台一起搜",
                color = if (enabled) Color.White.copy(alpha = 0.88f) else AppleGlassColors.TextSecondary,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = if (enabled) "已开启" else "开启",
            color = if (enabled) AppleGlassColors.AccentPink else Color.White,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(if (enabled) Color.White else AppleGlassColors.AccentPink)
                .padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

/**
 * Apple Spotlight-style Glass Search Bar & Collapsible Filter Drawer.
 */
@Composable
fun AppleSearchFilterPanel(
    state: UiState,
    vm: PornShopViewModel,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Spotlight Frosted Glass Search Input
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .appleGlassCard(
                    shape = RoundedCornerShape(18.dp),
                    surfaceColor = AppleGlassColors.GlassWhiteStrong,
                    elevation = 4.dp,
                )
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = Icons.Default.Search,
                contentDescription = null,
                tint = AppleGlassColors.AccentPink,
                modifier = Modifier.size(20.dp),
            )
            Spacer(modifier = Modifier.width(8.dp))
            Box(modifier = Modifier.weight(1f)) {
                if (state.searchQuery.isEmpty()) {
                    Text(
                        text = "搜索番号、创作者、标签或关键词…",
                        color = AppleGlassColors.TextTertiary,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                BasicTextField(
                    value = state.searchQuery,
                    onValueChange = vm::setSearchQuery,
                    maxLines = 4,
                    textStyle = TextStyle(
                        color = AppleGlassColors.TextPrimary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                    ),
                    cursorBrush = SolidColor(AppleGlassColors.AccentPink),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { vm.submitSearch() }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (state.searchQuery.isNotEmpty()) {
                IconButton(
                    onClick = { vm.setSearchQuery("") },
                    modifier = Modifier.size(28.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.Clear,
                        contentDescription = "清空",
                        tint = AppleGlassColors.TextSecondary,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            IconButton(
                onClick = vm::toggleSearchFilters,
                modifier = Modifier.size(30.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Tune,
                    contentDescription = "高级筛选",
                    tint = if (state.searchFiltersExpanded) AppleGlassColors.AccentPink else AppleGlassColors.TextSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
            Spacer(modifier = Modifier.width(4.dp))
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(AppleGlassColors.AccentGradient)
                    .clickable(onClick = vm::submitSearch)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            ) {
                Text(
                    text = "搜索",
                    color = Color.White,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        AggregateSearchButton(
            enabled = state.aggregateSearch,
            onClick = vm::toggleAggregateSearch,
        )

        // Quick Sort & Logic Chips
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Catalog.sorts.forEach { choice ->
                AppleGlassChip(
                    label = "排序: ${choice.label}",
                    selected = choice.key == state.sortBy,
                    onClick = { vm.setSort(choice.key) },
                )
            }
            AppleGlassChip(
                label = if (state.keywordLogic == "and") "多词: 匹配全部" else "多词: 匹配任一",
                selected = state.keywordLogic == "and",
                onClick = vm::toggleKeywordLogic,
            )
            AppleGlassChip(
                label = if (state.searchFiltersExpanded) "收起筛选 ▲" else "更多筛选 ▼",
                selected = state.searchFiltersExpanded,
                onClick = vm::toggleSearchFilters,
            )
        }

        // Collapsible Glass Filter Matrix
        AnimatedVisibility(visible = state.searchFiltersExpanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .appleGlassCard(shape = RoundedCornerShape(18.dp), elevation = 3.dp)
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(modifier = Modifier.weight(1f)) {
                        GlassFilterDropdown("分区", Catalog.categories, state.filterCategory, vm::setCategory)
                    }
                    Box(modifier = Modifier.weight(1f)) {
                        GlassFilterDropdown("发布时间", Catalog.times, state.filterTime, vm::setTime)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(modifier = Modifier.weight(1f)) {
                        GlassFilterDropdown("热度门槛", Catalog.viewFilters, state.filterViews, vm::setViews)
                    }
                    Box(modifier = Modifier.weight(1f)) {
                        GlassFilterDropdown("视频时长", Catalog.durations, state.filterDuration, vm::setDuration)
                    }
                }
            }
        }
    }
}

@Composable
private fun GlassFilterDropdown(
    label: String,
    choices: List<Choice>,
    selectedKey: String,
    onSelected: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = choices.firstOrNull { it.key == selectedKey }?.label ?: selectedKey
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Color.White.copy(alpha = 0.85f))
                .border(1.dp, Color(0xFFE2E8F0), RoundedCornerShape(12.dp))
                .clickable { expanded = true }
                .padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "$label: $selectedLabel",
                color = AppleGlassColors.TextPrimary,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Color.White),
        ) {
            choices.forEach { choice ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = choice.label,
                            color = if (choice.key == selectedKey) AppleGlassColors.AccentPink else AppleGlassColors.TextPrimary,
                            fontWeight = if (choice.key == selectedKey) FontWeight.Bold else FontWeight.Normal,
                        )
                    },
                    onClick = {
                        onSelected(choice.key)
                        expanded = false
                    },
                )
            }
        }
    }
}
