package com.pornshop.player.ui

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.pornshop.player.data.Catalog
import com.pornshop.player.data.DownloadCenter
import com.pornshop.player.data.DownloadStatus
import com.pornshop.player.data.DownloadTask
import com.pornshop.player.data.LibraryStore
import com.pornshop.player.data.ListPage
import com.pornshop.player.data.Playable
import com.pornshop.player.data.PornShopRepository
import com.pornshop.player.data.Sites
import com.pornshop.player.data.VideoItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class BrowseMode {
    HOME,
    BROWSE,
    SEARCH,
    LIBRARY,
}

enum class LibraryTab {
    FAVORITES,
    HISTORY,
    DOWNLOADS,
}

data class UiState(
    val mode: BrowseMode = BrowseMode.HOME,
    val homeSection: String = "home_hot",
    val listType: String = "hot",
    val libraryTab: LibraryTab = LibraryTab.FAVORITES,
    val page: Int = 1,
    val totalPage: Int = 1,
    val openEnded: Boolean = false,
    val searchQuery: String = "",
    val appliedQuery: String = "",
    val filterCategory: String = "all",
    val filterTime: String = "all",
    val filterViews: String = "all",
    val filterDuration: String = "all",
    val sortBy: String = "time",
    val keywordLogic: String = "or",
    val aggregateSearch: Boolean = false,
    val searchFiltersExpanded: Boolean = false,
    val isGridMode: Boolean = false,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val error: String? = null,
    val items: List<VideoItem> = emptyList(),
    val listEpoch: Int = 0,
    val playingItem: VideoItem? = null,
    val playable: Playable? = null,
    val selectedStreamIndex: Int = 0,
    val streamReloadNonce: Int = 0,
    val playLoading: Boolean = false,
    val playError: String? = null,
    val isMiniPlayer: Boolean = false,
    val autoPlayNext: Boolean = true,
    val favorites: List<VideoItem> = emptyList(),
    val history: List<VideoItem> = emptyList(),
    val activeHost: String = "v2.cdn199.com",
    val siteId: String = Sites.PORNSHOP,
)

class PornShopViewModel(app: Application) : AndroidViewModel(app) {
    private val repo = PornShopRepository()
    private val library = LibraryStore(app)
    private val sitePrefs = app.getSharedPreferences(SITE_PREFS, Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(UiState(activeHost = repo.currentHost().removePrefix("https://")))
    val state: StateFlow<UiState> = _state.asStateFlow()
    val downloads: StateFlow<List<DownloadTask>> = DownloadCenter.tasks
    private var listJob: Job? = null
    private var playJob: Job? = null

    init {
        DownloadCenter.install(app)
        val profile = Sites.byId(sitePrefs.getString(SITE_KEY, Sites.PORNSHOP))
        repo.useSite(profile)
        _state.update {
            it.copy(
                favorites = library.loadFavorites(),
                history = library.loadHistory(),
                siteId = profile.id,
                listType = Catalog.shortcutsFor(profile.id).first(),
            )
        }
        refresh()
    }

    fun switchSite(id: String) {
        val profile = Sites.byId(id)
        if (profile.id == _state.value.siteId) return
        listJob?.cancel()
        playJob?.cancel()
        repo.useSite(profile)
        sitePrefs.edit().putString(SITE_KEY, profile.id).apply()
        _state.update {
            it.copy(
                siteId = profile.id,
                mode = BrowseMode.HOME,
                listType = Catalog.shortcutsFor(profile.id).first(),
                page = 1,
                items = emptyList(),
                error = null,
                searchQuery = "",
                appliedQuery = "",
                playingItem = null,
                playable = null,
                selectedStreamIndex = 0,
                playLoading = false,
                playError = null,
                isMiniPlayer = false,
            )
        }
        refresh()
    }

    fun setMode(mode: BrowseMode) {
        if (_state.value.mode == mode) return
        listJob?.cancel()
        if (mode == BrowseMode.LIBRARY) {
            _state.update { it.copy(mode = mode, error = null, loading = false, loadingMore = false) }
            return
        }
        _state.update { it.copy(mode = mode, page = 1, items = emptyList(), error = null) }
        if (mode != BrowseMode.SEARCH || _state.value.appliedQuery.isNotBlank()) {
            refresh()
        }
    }

    fun setLibraryTab(tab: LibraryTab) {
        _state.update { it.copy(libraryTab = tab, mode = BrowseMode.LIBRARY) }
    }

    fun toggleGridMode() {
        _state.update { it.copy(isGridMode = !it.isGridMode) }
    }

    fun toggleSearchFilters() {
        _state.update { it.copy(searchFiltersExpanded = !it.searchFiltersExpanded) }
    }

    fun toggleAutoPlayNext() {
        _state.update { it.copy(autoPlayNext = !it.autoPlayNext) }
    }

    fun setListType(key: String) {
        if (_state.value.listType == key && _state.value.mode == BrowseMode.HOME) return
        _state.update { it.copy(listType = key, page = 1, items = emptyList(), mode = BrowseMode.HOME) }
        refresh()
    }

    fun setSearchQuery(q: String) {
        _state.update { it.copy(searchQuery = q) }
    }

    fun setCategory(key: String) = updateSearch { it.copy(filterCategory = key) }
    fun setTime(key: String) = updateSearch { it.copy(filterTime = key) }
    fun setViews(key: String) = updateSearch { it.copy(filterViews = key) }
    fun setDuration(key: String) = updateSearch { it.copy(filterDuration = key) }
    fun setSort(key: String) = updateSearch { it.copy(sortBy = key) }

    fun toggleKeywordLogic() {
        val next = if (_state.value.keywordLogic == "and") "or" else "and"
        updateSearch { it.copy(keywordLogic = next) }
    }

    fun toggleAggregateSearch() {
        updateSearch { it.copy(aggregateSearch = !it.aggregateSearch) }
    }

    private fun updateSearch(block: (UiState) -> UiState) {
        _state.update {
            block(it).copy(mode = BrowseMode.SEARCH, page = 1, items = emptyList())
        }
        if (_state.value.appliedQuery.isNotBlank() || _state.value.searchQuery.isNotBlank()) {
            val q = _state.value.searchQuery.trim().ifBlank { _state.value.appliedQuery }
            if (q.isNotBlank()) {
                _state.update { it.copy(appliedQuery = q) }
                refresh()
            }
        }
    }

    fun submitSearch() {
        val q = _state.value.searchQuery.trim()
        if (q.isEmpty()) return
        _state.update {
            it.copy(
                mode = BrowseMode.SEARCH,
                appliedQuery = q,
                page = 1,
                items = emptyList(),
                error = null,
                searchFiltersExpanded = false,
            )
        }
        refresh()
    }

    fun quickSearch(keyword: String) {
        val q = keyword.trim()
        if (q.isEmpty()) return
        _state.update {
            it.copy(
                mode = BrowseMode.SEARCH,
                searchQuery = q,
                appliedQuery = q,
                page = 1,
                items = emptyList(),
                error = null,
                isMiniPlayer = it.playingItem != null,
                searchFiltersExpanded = false,
            )
        }
        refresh()
    }

    fun refresh() {
        listJob?.cancel()
        val currentMode = _state.value.mode
        if (currentMode == BrowseMode.LIBRARY) return

        listJob = viewModelScope.launch {
            val snapshot = _state.value
            if (snapshot.mode == BrowseMode.SEARCH && snapshot.appliedQuery.isBlank()) {
                _state.update { it.copy(loading = false, items = emptyList(), error = null) }
                return@launch
            }
            _state.update {
                it.copy(loading = true, loadingMore = false, error = null, items = emptyList(), page = 1)
            }
            try {
                val result = withContext(Dispatchers.IO) { loadPage(snapshot, page = 1) }
                _state.update {
                    it.copy(
                        loading = false,
                        items = result.items,
                        page = result.page,
                        totalPage = result.totalPage,
                        openEnded = result.openEnded,
                        error = null,
                        listEpoch = it.listEpoch + 1,
                        activeHost = repo.currentHost().removePrefix("https://"),
                    )
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                _state.update { it.copy(loading = false, error = e.message ?: e.toString()) }
            }
        }
    }

    fun loadMore() {
        val s = _state.value
        if (s.loading || s.loadingMore) return
        if (s.mode == BrowseMode.LIBRARY) return
        if (s.page >= s.totalPage) return
        listJob?.cancel()
        listJob = viewModelScope.launch {
            val next = s.page + 1
            _state.update { it.copy(loadingMore = true, error = null) }
            try {
                val result = withContext(Dispatchers.IO) { loadPage(s, page = next) }
                _state.update {
                    val fresh = result.items.filter { row ->
                        it.items.none { old -> old.id == row.id && old.site == row.site }
                    }
                    if (result.items.isEmpty() || fresh.isEmpty()) {
                        it.copy(
                            loadingMore = false,
                            totalPage = (next - 1).coerceAtLeast(1),
                            openEnded = false,
                        )
                    } else {
                        it.copy(
                            loadingMore = false,
                            items = it.items + fresh,
                            page = result.page,
                            totalPage = result.totalPage,
                            openEnded = result.openEnded,
                            activeHost = repo.currentHost().removePrefix("https://"),
                        )
                    }
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                _state.update { it.copy(loadingMore = false, error = e.message ?: e.toString()) }
            }
        }
    }

    private fun loadPage(s: UiState, page: Int): ListPage = when (s.mode) {
        BrowseMode.HOME, BrowseMode.BROWSE -> repo.listVideos(s.listType, page)
        BrowseMode.SEARCH -> {
            val keyword = s.appliedQuery.ifBlank { s.searchQuery }
            if (s.aggregateSearch) {
                repo.searchAggregated(
                    keyword = keyword,
                    page = page,
                    category = s.filterCategory,
                    timeInDays = s.filterTime,
                    views = s.filterViews,
                    durationMins = s.filterDuration,
                    sortBy = s.sortBy,
                    keywordLogic = s.keywordLogic,
                )
            } else {
                repo.search(
                    keyword = keyword,
                    page = page,
                    category = s.filterCategory,
                    timeInDays = s.filterTime,
                    views = s.filterViews,
                    durationMins = s.filterDuration,
                    sortBy = s.sortBy,
                    keywordLogic = s.keywordLogic,
                )
            }
        }
        BrowseMode.LIBRARY -> ListPage(emptyList(), 1, 1, 0)
    }

    fun openPlayer(item: VideoItem, keepMini: Boolean = false) {
        val local = DownloadCenter.completedLocalUrl(item.id)
        if (local != null) {
            playJob?.cancel()
            playJob = viewModelScope.launch {
                _state.update { state ->
                    val updatedHistory = listOf(item) + state.history.filterNot { it.id == item.id }.take(49)
                    state.copy(
                        playingItem = item,
                        playable = Playable(
                            id = item.id,
                            title = item.displayTitle,
                            playUrl = local,
                            streamUrls = listOf(local),
                            cover = item.cover,
                            duration = item.duration,
                            user = item.user,
                            views = item.views,
                            timeLine = item.timeLine,
                            tags = item.tags,
                            pageOrigin = Sites.byId(item.site).pageOrigin,
                            site = item.site,
                        ),
                        selectedStreamIndex = 0,
                        playLoading = false,
                        playError = null,
                        isMiniPlayer = keepMini,
                        history = updatedHistory,
                        streamReloadNonce = state.streamReloadNonce + 1,
                    )
                }
                saveLibrary()
            }
            return
        }
        playJob?.cancel()
        playJob = viewModelScope.launch {
            _state.update { state ->
                val updatedHistory = listOf(item) + state.history.filterNot { it.id == item.id }.take(49)
                state.copy(
                    playingItem = item,
                    playable = null,
                    selectedStreamIndex = 0,
                    playLoading = true,
                    playError = null,
                    isMiniPlayer = keepMini,
                    history = updatedHistory,
                )
            }
            saveLibrary()
            try {
                val playable = withContext(Dispatchers.IO) { repo.resolvePlayable(item) }
                _state.update {
                    it.copy(
                        playable = playable,
                        selectedStreamIndex = 0,
                        playLoading = false,
                        playError = null,
                        activeHost = playable.activeHost.ifBlank { repo.currentHost().removePrefix("https://") },
                    )
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                _state.update { it.copy(playLoading = false, playError = e.message ?: e.toString()) }
            }
        }
    }

    fun minimizePlayer() {
        if (_state.value.playingItem != null) {
            _state.update { it.copy(isMiniPlayer = true) }
        }
    }

    fun expandPlayer() {
        if (_state.value.playingItem != null) {
            _state.update { it.copy(isMiniPlayer = false) }
        }
    }

    fun closePlayer() {
        playJob?.cancel()
        _state.update {
            it.copy(
                playingItem = null,
                playable = null,
                selectedStreamIndex = 0,
                playLoading = false,
                playError = null,
                isMiniPlayer = false,
            )
        }
    }

    fun selectServerLine(key: String) {
        val item = _state.value.playingItem ?: return
        if (_state.value.playable?.lineKey == key) return
        playJob?.cancel()
        playJob = viewModelScope.launch {
            _state.update { it.copy(playLoading = true, playError = null) }
            try {
                val playable = withContext(Dispatchers.IO) { repo.resolvePlayable(item, key) }
                _state.update {
                    it.copy(
                        playable = playable,
                        selectedStreamIndex = 0,
                        playLoading = false,
                        playError = null,
                        streamReloadNonce = it.streamReloadNonce + 1,
                        activeHost = playable.activeHost.ifBlank { repo.currentHost().removePrefix("https://") },
                    )
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                _state.update { it.copy(playLoading = false, playError = e.message ?: e.toString()) }
            }
        }
    }

    fun selectStreamIndex(index: Int) {
        val urls = _state.value.playable?.streamUrls ?: return
        if (index == _state.value.selectedStreamIndex) return
        if (index in urls.indices) {
            _state.update {
                it.copy(
                    selectedStreamIndex = index,
                    playable = it.playable?.copy(playUrl = urls[index]),
                    streamReloadNonce = it.streamReloadNonce + 1,
                )
            }
        }
    }

    fun switchHostAndReloadStream() {
        val currentItem = _state.value.playingItem ?: return
        val urls = _state.value.playable?.streamUrls.orEmpty()
        if (urls.size > 1 && _state.value.selectedStreamIndex + 1 < urls.size) {
            selectStreamIndex(_state.value.selectedStreamIndex + 1)
            return
        }
        val nextHost = repo.cycleHost()
        _state.update { it.copy(activeHost = nextHost.removePrefix("https://")) }
        openPlayer(currentItem, keepMini = _state.value.isMiniPlayer)
    }

    fun toggleFavorite(item: VideoItem) {
        _state.update { s ->
            val exists = s.favorites.any { it.id == item.id && it.site == item.site }
            val updated = if (exists) {
                s.favorites.filterNot { it.id == item.id && it.site == item.site }
            } else {
                listOf(item) + s.favorites
            }
            s.copy(favorites = updated)
        }
        saveLibrary()
    }

    fun clearHistory() {
        _state.update { it.copy(history = emptyList()) }
        saveLibrary()
    }

    fun playNext() {
        val snapshot = _state.value
        if (snapshot.playLoading) return
        val current = snapshot.playingItem ?: return
        val queue = currentQueue()
        val idx = queue.indexOfFirst { it.id == current.id }
        if (idx >= 0 && idx + 1 < queue.size) {
            openPlayer(queue[idx + 1], keepMini = snapshot.isMiniPlayer)
            return
        }
        if (snapshot.mode == BrowseMode.LIBRARY) return
        if (snapshot.loadingMore || snapshot.page >= snapshot.totalPage) return
        val keepMini = snapshot.isMiniPlayer
        listJob?.cancel()
        listJob = viewModelScope.launch {
            _state.update { it.copy(loadingMore = true, error = null) }
            try {
                val result = withContext(Dispatchers.IO) { loadPage(snapshot, page = snapshot.page + 1) }
                val fresh = result.items.filter { row ->
                    snapshot.items.none { old -> old.id == row.id && old.site == row.site }
                }
                _state.update {
                    if (fresh.isEmpty()) {
                        it.copy(loadingMore = false, totalPage = snapshot.page.coerceAtLeast(1), openEnded = false)
                    } else {
                        it.copy(
                            loadingMore = false,
                            items = it.items + fresh,
                            page = result.page,
                            totalPage = result.totalPage,
                            openEnded = result.openEnded,
                        )
                    }
                }
                fresh.firstOrNull()?.let { openPlayer(it, keepMini = keepMini) }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                _state.update { it.copy(loadingMore = false, error = e.message ?: e.toString()) }
            }
        }
    }

    fun playPrevious() {
        val current = _state.value.playingItem ?: return
        val queue = currentQueue()
        val idx = queue.indexOfFirst { it.id == current.id }
        if (idx > 0) {
            openPlayer(queue[idx - 1], keepMini = _state.value.isMiniPlayer)
        }
    }

    fun currentQueue(): List<VideoItem> {
        val s = _state.value
        val base = when (s.mode) {
            BrowseMode.LIBRARY -> if (s.libraryTab == LibraryTab.FAVORITES) s.favorites else s.history
            else -> s.items
        }
        return if (base.isNotEmpty()) base else s.history
    }

    fun reportPlayError(message: String) {
        if (_state.value.playingItem == null) return
        _state.update { it.copy(playLoading = false, playError = message) }
    }

    fun onDownloadClick(item: VideoItem) {
        val task = DownloadCenter.task(item.id)
        when (task?.status) {
            DownloadStatus.RUNNING -> DownloadCenter.pause(item.id)
            DownloadStatus.QUEUED -> {
                val ahead = DownloadCenter.tasks.value.any {
                    it.id != item.id &&
                        (it.status == DownloadStatus.RUNNING || it.status == DownloadStatus.QUEUED)
                }
                if (ahead) DownloadCenter.pause(item.id) else DownloadCenter.resume(item.id)
            }
            DownloadStatus.PAUSED -> DownloadCenter.resume(item.id)
            DownloadStatus.FAILED -> {
                if (task.remoteUrl.isBlank()) resolveAndEnqueue(item) else DownloadCenter.resume(item.id)
            }
            DownloadStatus.COMPLETED -> Unit
            null -> resolveAndEnqueue(item)
        }
    }

    fun deleteDownload(id: String) {
        DownloadCenter.delete(id)
    }

    private fun resolveAndEnqueue(item: VideoItem) {
        val known = _state.value.playable?.takeIf { it.id == item.id }?.playUrl
        if (!known.isNullOrBlank() && !known.startsWith("file:")) {
            DownloadCenter.enqueue(item, known)
            return
        }
        viewModelScope.launch {
            try {
                val playable = withContext(Dispatchers.IO) { repo.resolvePlayable(item) }
                DownloadCenter.enqueue(item, playable.playUrl)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DownloadCenter.fail(item, e.message ?: "解析失败")
            }
        }
    }

    fun buildVideoClient() = repo.buildVideoClient()

    private companion object {
        const val SITE_PREFS = "pornshop_site"
        const val SITE_KEY = "id"
    }

    private fun saveLibrary() {
        val s = _state.value
        library.save(s.favorites, s.history)
    }
}
