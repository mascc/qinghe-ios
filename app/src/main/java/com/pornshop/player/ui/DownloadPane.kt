package com.pornshop.player.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pornshop.player.data.DownloadStatus
import com.pornshop.player.data.DownloadTask
import java.util.Locale

@Composable
fun DownloadPane(
    tasks: List<DownloadTask>,
    onPlay: (DownloadTask) -> Unit,
    onToggle: (DownloadTask) -> Unit,
    onDelete: (DownloadTask) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (tasks.isEmpty()) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
                modifier = Modifier
                    .padding(horizontal = 28.dp)
                    .appleGlassCard(shape = RoundedCornerShape(22.dp))
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = "还没有下载",
                    color = AppleGlassColors.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = "在封面或播放页点下载。完成后断网也能从这里播放。",
                    color = AppleGlassColors.TextSecondary,
                    fontSize = 13.sp,
                )
            }
        }
        return
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(items = tasks, key = { it.id }) { task ->
            DownloadRow(task = task, onPlay = { onPlay(task) }, onToggle = { onToggle(task) }, onDelete = { onDelete(task) })
        }
    }
}

@Composable
private fun DownloadRow(
    task: DownloadTask,
    onPlay: () -> Unit,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .appleGlassCard(shape = RoundedCornerShape(18.dp), elevation = 4.dp)
            .padding(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .width(112.dp)
                    .aspectRatio(16f / 9f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFF1E293B))
                    .clickable(enabled = task.status == DownloadStatus.COMPLETED, onClick = onPlay),
            ) {
                CoverImage(
                    url = task.cover,
                    site = task.site,
                    contentDescription = task.title,
                    modifier = Modifier.fillMaxSize(),
                )
                if (task.status == DownloadStatus.COMPLETED) {
                    Icon(
                        imageVector = Icons.Default.PlayArrow,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier
                            .align(Alignment.Center)
                            .size(28.dp),
                    )
                }
            }
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = task.title,
                    color = AppleGlassColors.TextPrimary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = task.progressLabel() + task.bytesLabel(),
                    color = if (task.status == DownloadStatus.FAILED) {
                        AppleGlassColors.AccentPink
                    } else {
                        AppleGlassColors.TextSecondary
                    },
                    fontSize = 12.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (task.status == DownloadStatus.RUNNING || task.status == DownloadStatus.PAUSED) {
            Spacer(modifier = Modifier.height(8.dp))
            LinearProgressIndicator(
                progress = { (task.percent / 100f).coerceIn(0f, 1f) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(RoundedCornerShape(99.dp)),
                color = AppleGlassColors.AccentPink,
                trackColor = Color(0xFFE2E8F0),
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (task.status == DownloadStatus.COMPLETED) {
                AppleGlassChip(label = "播放", selected = true, onClick = onPlay, leadingIcon = Icons.Default.PlayArrow)
            } else {
                val (label, icon) = when (task.status) {
                    DownloadStatus.QUEUED, DownloadStatus.RUNNING -> "暂停" to Icons.Default.Pause
                    DownloadStatus.FAILED -> "重试" to Icons.Default.Refresh
                    else -> "继续" to Icons.Default.PlayArrow
                }
                AppleGlassChip(label = label, selected = false, onClick = onToggle, leadingIcon = icon)
            }
            AppleGlassChip(label = "删除", selected = false, onClick = onDelete, leadingIcon = Icons.Default.Delete)
        }
    }
}

private fun DownloadTask.bytesLabel(): String {
    if (bytes <= 0L) return ""
    val mb = bytes / (1024.0 * 1024.0)
    return " · " + String.format(Locale.US, "%.1f MB", mb)
}
