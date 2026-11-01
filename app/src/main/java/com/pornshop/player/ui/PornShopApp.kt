package com.pornshop.player.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.TextButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.border
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.pornshop.player.data.Catalog
import com.pornshop.player.data.DownloadStatus
import com.pornshop.player.data.DownloadTask
import com.pornshop.player.data.OfficialWebsite
import com.pornshop.player.data.OfficialWebsites
import com.pornshop.player.data.Sites
import com.pornshop.player.data.VideoItem
import com.pornshop.player.player.FloatingGlassMiniPlayer
import com.pornshop.player.player.PlaybackEngine
import com.pornshop.player.player.VideoPlayerScreen
import kotlinx.coroutines.flow.distinctUntilChanged

@androidx.annotation.OptIn(UnstableApi::class)
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PornShopApp(vm: PornShopViewModel) {
    val state by vm.state.collectAsState()
    val downloads by vm.downloads.collectAsState()
    val context = LocalContext.current
    val requestNotifications = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { }
    val ensureNotify: () -> Unit = {
        if (
            Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    val downloadedIds = remember(downloads) {
        downloads.filter { it.status == DownloadStatus.COMPLETED }.map { it.id }.toSet()
    }
    val listState = rememberLazyListState()
    val gridState = rememberLazyGridState()
    val videoClient = remember { vm.buildVideoClient() }
    val engine = remember { PlaybackEngine(context.applicationContext) }
    var livePlayer by remember { mutableStateOf<ExoPlayer?>(null) }
    var showReleaseNotes by remember { mutableStateOf(false) }
    var showPlatformPicker by remember { mutableStateOf(false) }
    var officialWebsite by remember { mutableStateOf<OfficialWebsite?>(null) }
    LaunchedEffect(Unit) {
        if (AppRelease.shouldPrompt(context)) showReleaseNotes = true
    }
    val playId = state.playingItem?.id
    val playUrl = state.playable?.playUrl
    val playOrigin = state.playable?.pageOrigin ?: Sites.byId(state.playingItem?.site ?: state.siteId).pageOrigin

    LaunchedEffect(playId, playUrl, state.streamReloadNonce, playOrigin) {
        livePlayer = when {
            playId != null && !playUrl.isNullOrBlank() ->
                engine.prepare(playId, playUrl, state.streamReloadNonce, videoClient, playOrigin)
            playId == null -> {
                engine.release()
                null
            }
            else -> {
                engine.player?.pause()
                engine.player
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose { engine.release() }
    }

    DisposableEffect(livePlayer, state.autoPlayNext) {
        val player = livePlayer
        if (player == null) {
            onDispose { }
        } else {
            val listener = object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    val stillCurrent = player == engine.player && vm.state.value.playingItem != null
                    if (stillCurrent) {
                        vm.reportPlayError(error.message ?: "播放失败")
                    }
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    val stillCurrent = player == engine.player && vm.state.value.playingItem != null
                    if (
                        playbackState == Player.STATE_ENDED &&
                        stillCurrent &&
                        vm.state.value.autoPlayNext &&
                        !vm.state.value.playLoading
                    ) {
                        vm.playNext()
                    }
                }
            }
            player.addListener(listener)
            onDispose { player.removeListener(listener) }
        }
    }

    DisposableEffect(playId) {
        val activity = context as? Activity
        if (playId != null) {
            activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        onDispose {
            activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    val activeFeedItems: List<VideoItem> = when (state.mode) {
        BrowseMode.LIBRARY -> {
            if (state.libraryTab == LibraryTab.FAVORITES) state.favorites else state.history
        }
        else -> state.items
    }

    LaunchedEffect(
        state.mode,
        state.listType,
        state.libraryTab,
        state.appliedQuery,
        state.filterCategory,
        state.filterTime,
        state.filterViews,
        state.filterDuration,
        state.sortBy,
        state.keywordLogic,
        state.listEpoch,
    ) {
        val showingDownloads = state.mode == BrowseMode.LIBRARY && state.libraryTab == LibraryTab.DOWNLOADS
        if (!showingDownloads && !state.loading && activeFeedItems.isNotEmpty()) {
            if (state.isGridMode) gridState.scrollToItem(0) else listState.scrollToItem(0)
        }
    }

    LaunchedEffect(listState, state.items.size, state.loadingMore, state.page, state.totalPage, state.isGridMode) {
        if (state.isGridMode) return@LaunchedEffect
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            last to info.totalItemsCount
        }
            .distinctUntilChanged()
            .collect { (last, total) ->
                if (total > 0 && last >= total - 3) vm.loadMore()
            }
    }

    LaunchedEffect(gridState, state.items.size, state.loadingMore, state.page, state.totalPage, state.isGridMode) {
        if (!state.isGridMode) return@LaunchedEffect
        snapshotFlow {
            val info = gridState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            last to info.totalItemsCount
        }
            .distinctUntilChanged()
            .collect { (last, total) ->
                if (total > 0 && last >= total - 4) vm.loadMore()
            }
    }

    // Direct provider pages stay isolated from the native video stack.  The
    // WebView does not inject scripts, intercept media, or change requests.
    if (officialWebsite != null) {
        OfficialWebsiteBrowser(
            website = officialWebsite!!,
            onClose = { officialWebsite = null },
        )
    // Full Watch Page / Player Mode
    } else if (state.playingItem != null && !state.isMiniPlayer) {
        val currentItem = state.playingItem!!
        val upNext = remember(currentItem.id, state.items, state.history) {
            vm.currentQueue().filterNot { it.id == currentItem.id }
        }
        VideoPlayerScreen(
            item = currentItem,
            playable = state.playable,
            loading = state.playLoading,
            error = state.playError,
            selectedStreamIndex = state.selectedStreamIndex,
            isFavorite = state.favorites.any { it.id == currentItem.id },
            autoPlayNext = state.autoPlayNext,
            upNextItems = upNext,
            player = livePlayer,
            onBack = vm::closePlayer,
            onMinimize = vm::minimizePlayer,
            onToggleFavorite = { vm.toggleFavorite(currentItem) },
            onSelectStream = vm::selectStreamIndex,
            onSelectLine = vm::selectServerLine,
            onSwitchHost = vm::switchHostAndReloadStream,
            onToggleAutoPlayNext = vm::toggleAutoPlayNext,
            onPlayNext = vm::playNext,
            onPlayPrevious = vm::playPrevious,
            onSelectUpNext = { next -> vm.openPlayer(next, keepMini = false) },
            onSearchTagOrUploader = vm::quickSearch,
            downloadLabel = downloadActionLabel(downloads.firstOrNull { it.id == currentItem.id }),
            downloadActive = downloads.any {
                it.id == currentItem.id &&
                    (it.status == DownloadStatus.COMPLETED || it.status == DownloadStatus.RUNNING)
            },
            onDownload = {
                ensureNotify()
                vm.onDownloadClick(currentItem)
            },
        )
    } else {

    // Main Apple Light Glass Feed Screen
    AppleGlassBackground {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .navigationBarsPadding(),
        ) {
            Column(
                modifier = Modifier.fillMaxSize(),
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .appleGlassCard(
                            shape = RoundedCornerShape(bottomStart = 22.dp, bottomEnd = 22.dp),
                            surfaceColor = AppleGlassColors.GlassWhiteStrong,
                            elevation = 6.dp,
                        )
                        .statusBarsPadding()
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(36.dp)
                                .clip(RoundedCornerShape(11.dp))
                                .background(AppleGlassColors.AccentGradient),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Default.PlayArrow,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(22.dp),
                            )
                        }
                        Spacer(modifier = Modifier.width(10.dp))
                        val site = Sites.byId(state.siteId)
                        Column {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    text = site.label,
                                    color = AppleGlassColors.TextPrimary,
                                    fontSize = 18.sp,
                                    fontWeight = FontWeight.ExtraBold,
                                )
                                Spacer(modifier = Modifier.width(6.dp))
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(6.dp))
                                        .background(AppleGlassColors.AccentPink.copy(alpha = 0.12f))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                ) {
                                    Text(
                                        text = "v${AppRelease.versionName}",
                                        color = AppleGlassColors.AccentPink,
                                        fontSize = 10.sp,
                                        fontWeight = FontWeight.Bold,
                                    )
                                }
                            }
                        }
                    }

                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(AppleGlassColors.AccentPink.copy(alpha = 0.12f))
                                .clickable { showPlatformPicker = true }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        ) {
                            Text(
                                text = "切换平台",
                                color = AppleGlassColors.AccentPink,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                        IconButton(
                            onClick = { vm.setMode(BrowseMode.SEARCH) },
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Default.Search,
                                contentDescription = "搜索",
                                tint = if (state.mode == BrowseMode.SEARCH) AppleGlassColors.AccentPink else AppleGlassColors.TextPrimary,
                            )
                        }
                        IconButton(
                            onClick = vm::toggleGridMode,
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(
                                imageVector = if (state.isGridMode) Icons.Default.ViewAgenda else Icons.Default.GridView,
                                contentDescription = "切换视图",
                                tint = AppleGlassColors.TextPrimary,
                            )
                        }
                        IconButton(
                            onClick = vm::refresh,
                            enabled = !state.loading,
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "刷新",
                                tint = AppleGlassColors.TextPrimary,
                            )
                        }
                    }
                }

                Column(modifier = Modifier.padding(horizontal = 14.dp)) {
                Spacer(modifier = Modifier.height(8.dp))

                val modes = listOf(
                    BrowseMode.HOME to ("首页" to Icons.Default.Home),
                    BrowseMode.SEARCH to ("搜索" to Icons.Default.Search),
                    BrowseMode.LIBRARY to ("片库" to Icons.Default.Bookmarks),
                )
                AppleSegmentedControl(
                    items = modes.map { it.second },
                    selectedIndex = modes.indexOfFirst { it.first == state.mode }.coerceAtLeast(0),
                    onSelect = { idx -> vm.setMode(modes[idx].first) },
                )

                Spacer(modifier = Modifier.height(6.dp))

                when (state.mode) {
                    BrowseMode.HOME, BrowseMode.BROWSE -> {
                        HomeCategoryBar(
                            siteId = state.siteId,
                            selectedKey = state.listType,
                            onSelect = vm::setListType,
                        )
                    }
                    BrowseMode.SEARCH -> {
                        AppleSearchFilterPanel(state = state, vm = vm)
                    }
                    BrowseMode.LIBRARY -> {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState())
                                .padding(vertical = 2.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            AppleGlassChip(
                                label = "我的收藏 (${state.favorites.size})",
                                selected = state.libraryTab == LibraryTab.FAVORITES,
                                onClick = { vm.setLibraryTab(LibraryTab.FAVORITES) },
                            )
                            AppleGlassChip(
                                label = "观看足迹 (${state.history.size})",
                                selected = state.libraryTab == LibraryTab.HISTORY,
                                onClick = { vm.setLibraryTab(LibraryTab.HISTORY) },
                            )
                            AppleGlassChip(
                                label = "下载 (${downloads.size})",
                                selected = state.libraryTab == LibraryTab.DOWNLOADS,
                                onClick = { vm.setLibraryTab(LibraryTab.DOWNLOADS) },
                            )
                        }
                    }
                }

                // 4. Status Metadata Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 4.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = when {
                            state.loading -> "正在从加密节点同步视频流…"
                            state.mode == BrowseMode.LIBRARY -> when (state.libraryTab) {
                                LibraryTab.FAVORITES -> "共收藏 ${state.favorites.size} 部视频"
                                LibraryTab.HISTORY -> "最近观看 ${state.history.size} 部视频"
                                LibraryTab.DOWNLOADS -> {
                                    val done = downloads.count { it.status == DownloadStatus.COMPLETED }
                                    val active = downloads.count {
                                        it.status == DownloadStatus.RUNNING || it.status == DownloadStatus.QUEUED
                                    }
                                    "已离线 $done 部 · 进行中 $active"
                                }
                            }
                            state.mode == BrowseMode.HOME || state.mode == BrowseMode.BROWSE ->
                                if (state.openEnded) {
                                    "第 ${state.page} 页 · 已加载 ${state.items.size} 部"
                                } else {
                                    "第 ${state.page}/${state.totalPage} 页 · 已加载 ${state.items.size} 部"
                                }
                            state.mode == BrowseMode.SEARCH && state.appliedQuery.isBlank() -> "输入关键词探索全站资源"
                            state.mode == BrowseMode.SEARCH -> "「${state.appliedQuery}」第 ${state.page} 页 · 已加载 ${state.items.size} 部"
                            else -> "第 ${state.page}/${state.totalPage} 页 · 已加载 ${state.items.size} 部"
                        },
                        color = AppleGlassColors.TextSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    if (state.mode == BrowseMode.LIBRARY &&
                        state.libraryTab == LibraryTab.HISTORY &&
                        state.history.isNotEmpty()
                    ) {
                        Spacer(modifier = Modifier.width(8.dp))
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .clickable(onClick = vm::clearHistory)
                                .padding(horizontal = 4.dp, vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                imageVector = Icons.Default.DeleteSweep,
                                contentDescription = null,
                                tint = AppleGlassColors.TextSecondary,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(
                                text = "清空记录",
                                color = AppleGlassColors.TextSecondary,
                                fontSize = 12.sp,
                                maxLines = 1,
                            )
                        }
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = if (state.isGridMode) "视图: 双列紧凑" else "视图: 宽屏大卡",
                        color = AppleGlassColors.AccentPink,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        modifier = Modifier.clickable(onClick = vm::toggleGridMode),
                    )
                }
                }
                }

                val bottomPadding = if (state.playingItem != null && state.isMiniPlayer) 92.dp else 20.dp
                val feedPadding = Modifier.padding(horizontal = 14.dp)
                val showingDownloads = state.mode == BrowseMode.LIBRARY &&
                    state.libraryTab == LibraryTab.DOWNLOADS

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                ) {
                when {
                    showingDownloads -> {
                        DownloadPane(
                            tasks = downloads,
                            onPlay = { task -> vm.openPlayer(task.toVideoItem()) },
                            onToggle = { task ->
                                ensureNotify()
                                vm.onDownloadClick(task.toVideoItem())
                            },
                            onDelete = { task -> vm.deleteDownload(task.id) },
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    state.loading && activeFeedItems.isEmpty() -> {
                        LazyColumn(
                            modifier = Modifier.fillMaxSize().then(feedPadding),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            contentPadding = PaddingValues(bottom = bottomPadding),
                        ) {
                            items(4) {
                                YouTubeCardShimmer(isGrid = false)
                            }
                        }
                    }
                    state.error != null && activeFeedItems.isEmpty() -> {
                        Box(
                            modifier = Modifier.fillMaxSize().then(feedPadding),
                            contentAlignment = Alignment.Center,
                        ) {
                            Column(
                                modifier = Modifier
                                    .appleGlassCard(shape = RoundedCornerShape(22.dp))
                                    .padding(24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    text = "节点请求失败",
                                    color = AppleGlassColors.TextPrimary,
                                    fontSize = 16.sp,
                                    fontWeight = FontWeight.Bold,
                                )
                                Spacer(modifier = Modifier.height(6.dp))
                                Text(
                                    text = state.error.orEmpty(),
                                    color = AppleGlassColors.TextSecondary,
                                    fontSize = 12.sp,
                                )
                                Spacer(modifier = Modifier.height(14.dp))
                                AppleGlassChip(
                                    label = "立即重试",
                                    selected = true,
                                    onClick = vm::refresh,
                                )
                            }
                        }
                    }
                    activeFeedItems.isEmpty() -> {
                        Box(
                            modifier = Modifier.fillMaxSize().then(feedPadding),
                            contentAlignment = Alignment.Center,
                        ) {
                            Column(
                                modifier = Modifier
                                    .appleGlassCard(shape = RoundedCornerShape(22.dp))
                                    .padding(24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    text = when (state.mode) {
                                        BrowseMode.LIBRARY -> "暂无记录，快去观看或收藏心仪的视频吧"
                                        BrowseMode.SEARCH -> "输入关键词并点击搜索，即可探索海量视频"
                                        else -> "暂无视频数据"
                                    },
                                    color = AppleGlassColors.TextSecondary,
                                    fontSize = 13.sp,
                                )
                            }
                        }
                    }
                    state.isGridMode -> {
                        LazyVerticalGrid(
                            columns = GridCells.Fixed(2),
                            state = gridState,
                            modifier = Modifier.fillMaxSize().then(feedPadding),
                            contentPadding = PaddingValues(bottom = bottomPadding),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            items(items = activeFeedItems, key = { "${it.site}:${it.id}" }) { item ->
                                AppleGridVideoCard(
                                    item = item,
                                    isFavorite = state.favorites.any { it.id == item.id && it.site == item.site },
                                    downloaded = item.id in downloadedIds,
                                    showSite = state.mode == BrowseMode.SEARCH && state.aggregateSearch,
                                    onClick = { vm.openPlayer(item) },
                                    onToggleFavorite = { vm.toggleFavorite(item) },
                                    onDownload = {
                                        ensureNotify()
                                        vm.onDownloadClick(item)
                                    },
                                )
                            }
                            if (state.loadingMore) {
                                item(span = { GridItemSpan(2) }, key = "_grid_loading_more") {
                                    Box(
                                        modifier = Modifier.fillMaxWidth().padding(14.dp),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        CircularProgressIndicator(
                                            color = AppleGlassColors.AccentPink,
                                            modifier = Modifier.size(26.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }
                    else -> {
                        LazyColumn(
                            state = listState,
                            modifier = Modifier.fillMaxSize().then(feedPadding),
                            contentPadding = PaddingValues(bottom = bottomPadding),
                            verticalArrangement = Arrangement.spacedBy(14.dp),
                        ) {
                            items(items = activeFeedItems, key = { "${it.site}:${it.id}" }) { item ->
                                YouTubeFeedCard(
                                    item = item,
                                    isFavorite = state.favorites.any { it.id == item.id && it.site == item.site },
                                    downloaded = item.id in downloadedIds,
                                    showSite = state.mode == BrowseMode.SEARCH && state.aggregateSearch,
                                    onClick = { vm.openPlayer(item) },
                                    onToggleFavorite = { vm.toggleFavorite(item) },
                                    onDownload = {
                                        ensureNotify()
                                        vm.onDownloadClick(item)
                                    },
                                    onClickUploader = vm::quickSearch,
                                )
                            }
                            if (state.loadingMore) {
                                item(key = "_list_loading_more") {
                                    Box(
                                        modifier = Modifier.fillMaxWidth().padding(14.dp),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        CircularProgressIndicator(
                                            color = AppleGlassColors.AccentPink,
                                            modifier = Modifier.size(26.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                }
            }

            // Floating Apple Light Glass Mini-Player Bar at bottom
            AnimatedVisibility(
                visible = state.playingItem != null && state.isMiniPlayer,
                enter = slideInVertically { it },
                exit = slideOutVertically { it },
                modifier = Modifier.align(Alignment.BottomCenter),
            ) {
                state.playingItem?.let { current ->
                    FloatingGlassMiniPlayer(
                        item = current,
                        playable = state.playable,
                        player = livePlayer,
                        loading = state.playLoading,
                        onExpand = vm::expandPlayer,
                        onPlayNext = vm::playNext,
                        onClose = vm::closePlayer,
                    )
                }
            }
        }
    }
    if (showReleaseNotes) {
        ReleaseNotesDialog(
            onDismiss = {
                AppRelease.markPrompted(context)
                showReleaseNotes = false
            },
        )
    }
    if (showPlatformPicker) {
        PlatformSwitchDialog(
            currentId = state.siteId,
            onDismiss = { showPlatformPicker = false },
            onSwitch = { id ->
                showPlatformPicker = false
                vm.switchSite(id)
            },
            onOpenOfficialWebsite = { website ->
                showPlatformPicker = false
                officialWebsite = website
            },
        )
    }
    }
}

@Composable
private fun ReleaseNotesDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("版本 ${AppRelease.versionName}") },
        text = {
            Column {
                Text(
                    text = "更新说明",
                    color = AppleGlassColors.TextSecondary,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(bottom = 10.dp),
                )
                AppRelease.notes.forEach { line ->
                    Text(
                        text = "· $line",
                        color = AppleGlassColors.TextPrimary,
                        fontSize = 15.sp,
                        lineHeight = 22.sp,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("知道了")
            }
        },
    )
}

@Composable
private fun PlatformSwitchDialog(
    currentId: String,
    onDismiss: () -> Unit,
    onSwitch: (String) -> Unit,
    onOpenOfficialWebsite: (OfficialWebsite) -> Unit,
) {
    var selected by remember(currentId) { mutableStateOf(currentId) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("切换平台") },
        text = {
            Column {
                Sites.all.forEach { site ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .clickable { selected = site.id }
                            .padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = selected == site.id,
                            onClick = { selected = site.id },
                        )
                        Text(
                            text = site.label,
                            color = AppleGlassColors.TextPrimary,
                            fontSize = 16.sp,
                            fontWeight = if (selected == site.id) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    }
                }
                Text(
                    text = "官网访问",
                    color = AppleGlassColors.TextSecondary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 12.dp, bottom = 2.dp),
                )
                OfficialWebsites.all.forEach { website ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .clickable { onOpenOfficialWebsite(website) }
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = website.label,
                            color = AppleGlassColors.TextPrimary,
                            fontSize = 16.sp,
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSwitch(selected) },
                enabled = selected != currentId,
            ) {
                Text("切换")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        },
    )
}

private fun downloadActionLabel(task: DownloadTask?): String = when (task?.status) {
    null -> "下载"
    DownloadStatus.QUEUED -> "排队中"
    DownloadStatus.RUNNING -> if (task.total > 0) "下载 ${task.percent}%" else "下载中"
    DownloadStatus.PAUSED -> "继续下载"
    DownloadStatus.FAILED -> "重试下载"
    DownloadStatus.COMPLETED -> "已离线"
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun HomeCategoryBar(
    siteId: String,
    selectedKey: String,
    onSelect: (String) -> Unit,
) {
    var showAll by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val groups = Catalog.groupsFor(siteId)
    val types = Catalog.typesFor(siteId)
    val shortcutKeys = Catalog.shortcutsFor(siteId)
    val shortcuts = types.filter { it.key in shortcutKeys }
    val selected = types.firstOrNull { it.key == selectedKey }
    val visible = buildList {
        if (selected != null && selected.key !in shortcutKeys) add(selected)
        addAll(shortcuts)
    }.distinctBy { it.key }.take(2)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        visible.forEach { type ->
            AppleGlassChip(
                label = type.label,
                selected = type.key == selectedKey,
                onClick = { onSelect(type.key) },
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .border(1.dp, AppleGlassColors.AccentPink.copy(alpha = 0.45f), RoundedCornerShape(999.dp))
                .background(AppleGlassColors.AccentPink.copy(alpha = 0.08f))
                .clickable { showAll = true }
                .padding(horizontal = 12.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "全部分类",
                color = AppleGlassColors.AccentPink,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Icon(
                imageVector = Icons.Default.KeyboardArrowDown,
                contentDescription = null,
                tint = AppleGlassColors.AccentPink,
                modifier = Modifier.size(18.dp),
            )
        }
    }

    if (showAll) {
        ModalBottomSheet(
            onDismissRequest = { showAll = false },
            sheetState = sheetState,
            containerColor = Color(0xFFF7F8FC),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .navigationBarsPadding()
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 18.dp),
            ) {
                Text(
                    text = "全部分类",
                    color = AppleGlassColors.TextPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(modifier = Modifier.height(12.dp))
                groups.forEach { group ->
                    Text(
                        text = group.title,
                        color = AppleGlassColors.TextTertiary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        group.items.forEach { type ->
                            AppleGlassChip(
                                label = type.label,
                                selected = type.key == selectedKey,
                                onClick = {
                                    showAll = false
                                    onSelect(type.key)
                                },
                            )
                        }
                    }
                    Spacer(modifier = Modifier.height(14.dp))
                }
            }
        }
    }
}
