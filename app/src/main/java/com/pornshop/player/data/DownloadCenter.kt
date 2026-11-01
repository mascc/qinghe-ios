package com.pornshop.player.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.pornshop.player.download.DownloadKeeperService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 一次只下一个，暂停后保留已完成分片，下次从断点继续。
 * 完成后用本地 m3u8 播放，不依赖网络。
 */
object DownloadCenter {
    private val ready = AtomicBoolean(false)
    private lateinit var appContext: Context
    private lateinit var store: DownloadStore
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gate = Mutex()
    private val _tasks = MutableStateFlow<List<DownloadTask>>(emptyList())
    val tasks: StateFlow<List<DownloadTask>> = _tasks.asStateFlow()

    private var activeId: String? = null
    private var activeJob: Job? = null
    private val generation = HashMap<String, Int>()

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .followRedirects(true)
            .build()
    }

    fun install(context: Context) {
        if (!ready.compareAndSet(false, true)) return
        appContext = context.applicationContext
        store = DownloadStore(appContext)
        val restored = store.load().map { task ->
            if (task.status == DownloadStatus.RUNNING) task.copy(status = DownloadStatus.QUEUED) else task
        }
        _tasks.value = restored
        store.save(restored)
    }

    fun hasPending(): Boolean = _tasks.value.any {
        it.status == DownloadStatus.QUEUED || it.status == DownloadStatus.RUNNING
    }

    fun ensureRunning() {
        if (!ready.get()) return
        if (!hasPending() && activeId == null) return
        val intent = Intent(appContext, DownloadKeeperService::class.java)
        androidx.core.content.ContextCompat.startForegroundService(appContext, intent)
    }

    fun kick() {
        if (!ready.get()) return
        scope.launch {
            gate.withLock { tryStartLocked() }
            if (hasPending() || activeId != null) ensureRunning()
        }
    }

    fun task(id: String): DownloadTask? = _tasks.value.firstOrNull { it.id == id }

    fun completedLocalUrl(id: String): String? =
        task(id)?.takeIf { it.status == DownloadStatus.COMPLETED }?.localUrl?.takeIf { it.isNotBlank() }

    fun enqueue(item: VideoItem, remoteUrl: String) {
        if (!ready.get() || remoteUrl.isBlank()) return
        scope.launch {
            gate.withLock {
                val current = _tasks.value
                val existing = current.firstOrNull { it.id == item.id }
                if (existing?.status == DownloadStatus.COMPLETED) return@withLock
                if (existing?.status == DownloadStatus.RUNNING || existing?.status == DownloadStatus.QUEUED) return@withLock
                val next = (existing ?: item.toTask(remoteUrl)).copy(
                    remoteUrl = remoteUrl.ifBlank { existing?.remoteUrl.orEmpty() },
                    title = item.displayTitle,
                    cover = item.cover ?: existing?.cover,
                    status = DownloadStatus.QUEUED,
                    error = null,
                    localUrl = null,
                    updatedAt = System.currentTimeMillis(),
                )
                publish(upsert(current, next))
                tryStartLocked()
            }
            ensureRunning()
        }
    }

    fun fail(item: VideoItem, message: String) {
        if (!ready.get()) return
        scope.launch {
            gate.withLock {
                val next = (task(item.id) ?: item.toTask("")).copy(
                    status = DownloadStatus.FAILED,
                    error = message.take(120),
                    updatedAt = System.currentTimeMillis(),
                )
                publish(upsert(_tasks.value, next))
            }
        }
    }

    fun pause(id: String) {
        if (!ready.get()) return
        scope.launch {
            val job = gate.withLock {
                generation[id] = (generation[id] ?: 0) + 1
                val job = detachActive(id)
                update(id) {
                    it.copy(status = DownloadStatus.PAUSED, error = null, updatedAt = System.currentTimeMillis())
                }
                tryStartLocked()
                job
            }
            job?.cancel()
        }
    }

    fun resume(id: String) {
        if (!ready.get()) return
        scope.launch {
            val url = task(id)?.remoteUrl.orEmpty()
            if (url.isBlank()) return@launch
            gate.withLock {
                update(id) {
                    it.copy(status = DownloadStatus.QUEUED, error = null, updatedAt = System.currentTimeMillis())
                }
                // 前面没有正在下的任务时，同一次加锁里直接开下，避免界面停在「排队中」。
                tryStartLocked()
            }
            ensureRunning()
        }
    }

    fun delete(id: String) {
        if (!ready.get()) return
        scope.launch {
            val job = gate.withLock {
                generation[id] = (generation[id] ?: 0) + 1
                val job = detachActive(id)
                publish(_tasks.value.filterNot { it.id == id })
                tryStartLocked()
                job
            }
            job?.cancel()
            runCatching { offlineDir(id).deleteRecursively() }
        }
    }

    /** 调用方必须已持有 [gate]。暂停时立刻让出下载位，不能等已取消的任务自己收尾。 */
    private fun detachActive(id: String): Job? {
        if (activeId != id) return null
        val job = activeJob
        activeId = null
        activeJob = null
        return job
    }

    /** 调用方必须已持有 [gate]。只有下载位空着才启动队首。 */
    private fun tryStartLocked() {
        if (activeId != null) return
        val next = _tasks.value.firstOrNull { it.status == DownloadStatus.QUEUED && it.remoteUrl.isNotBlank() }
        if (next == null) {
            if (_tasks.value.none { it.status == DownloadStatus.RUNNING }) {
                appContext.stopService(Intent(appContext, DownloadKeeperService::class.java))
            }
            return
        }
        val gen = generation[next.id] ?: 0
        activeId = next.id
        update(next.id) {
            it.copy(status = DownloadStatus.RUNNING, error = null, updatedAt = System.currentTimeMillis())
        }
        val running = task(next.id) ?: next
        activeJob = scope.launch { runDownload(running, gen) }
    }

    private suspend fun runDownload(task: DownloadTask, gen: Int) {
        val dir = offlineDir(task.id)
        try {
            val origin = Sites.byId(task.site).pageOrigin
            val index = HlsLocalDownloader(client, origin).download(task.remoteUrl, dir) { done, total ->
                scope.launch {
                    gate.withLock {
                        if ((generation[task.id] ?: 0) != gen) return@withLock
                        update(task.id) { current ->
                            if (current.status != DownloadStatus.RUNNING) current
                            else current.copy(done = done, total = total)
                        }
                    }
                }
            }
            val bytes = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
            val local = Uri.fromFile(index).toString()
            gate.withLock {
                if ((generation[task.id] ?: 0) != gen) return@withLock
                update(task.id) {
                    it.copy(
                        status = DownloadStatus.COMPLETED,
                        localUrl = local,
                        bytes = bytes,
                        error = null,
                        done = it.total.coerceAtLeast(it.done),
                        updatedAt = System.currentTimeMillis(),
                    )
                }
            }
        } catch (e: CancellationException) {
            // 暂停或删除已经改过状态
        } catch (e: Exception) {
            gate.withLock {
                if ((generation[task.id] ?: 0) != gen) return@withLock
                val current = task(task.id)
                if (current?.status == DownloadStatus.RUNNING) {
                    update(task.id) {
                        it.copy(
                            status = DownloadStatus.FAILED,
                            error = (e.message ?: "下载失败").take(120),
                            updatedAt = System.currentTimeMillis(),
                        )
                    }
                }
            }
        } finally {
            withContext(NonCancellable) {
                gate.withLock {
                    val stillOwns = activeId == task.id && (generation[task.id] ?: 0) == gen
                    if (stillOwns) {
                        activeId = null
                        activeJob = null
                        tryStartLocked()
                    }
                }
            }
        }
    }

    private fun offlineDir(id: String): File {
        val root = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        return File(root, "offline/${safeId(id)}")
    }

    private fun update(id: String, block: (DownloadTask) -> DownloadTask) {
        val next = _tasks.value.map { if (it.id == id) block(it) else it }
        publish(next)
    }

    private fun upsert(tasks: List<DownloadTask>, task: DownloadTask): List<DownloadTask> {
        val without = tasks.filterNot { it.id == task.id }
        return listOf(task) + without
    }

    private fun publish(tasks: List<DownloadTask>) {
        _tasks.value = tasks
        store.save(tasks)
    }

    private fun VideoItem.toTask(remoteUrl: String) = DownloadTask(
        id = id,
        title = displayTitle,
        cover = cover,
        duration = duration,
        views = views,
        user = user,
        vip = vip,
        timeLine = timeLine,
        videoType = videoType,
        tags = tags,
        site = site,
        remoteUrl = remoteUrl,
        localUrl = null,
        status = DownloadStatus.QUEUED,
    )

    private fun safeId(id: String): String =
        id.replace(Regex("[^A-Za-z0-9._-]"), "_").take(80).ifBlank { "video" }
}
