package com.pornshop.player

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.viewmodel.compose.viewModel
import com.pornshop.player.data.DownloadCenter
import com.pornshop.player.ui.AppleGlassColors
import com.pornshop.player.ui.PornShopApp
import com.pornshop.player.ui.PornShopViewModel
import com.pornshop.player.ui.StudyCoverScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DownloadCenter.install(applicationContext)
        if (DownloadCenter.hasPending()) DownloadCenter.ensureRunning()
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(
                AndroidColor.TRANSPARENT,
                AndroidColor.TRANSPARENT,
            ),
            navigationBarStyle = SystemBarStyle.light(
                AndroidColor.TRANSPARENT,
                AndroidColor.TRANSPARENT,
            ),
        )
        setContent {
            PornShopGlassTheme {
                var unlocked by remember { mutableStateOf(false) }
                if (!unlocked) {
                    StudyCoverScreen(onUnlock = { unlocked = true })
                } else {
                    val vm: PornShopViewModel = viewModel()
                    BackHandler {
                        vm.closePlayer()
                        unlocked = false
                    }
                    PornShopApp(vm)
                }
            }
        }
    }
}

@Composable
private fun PornShopGlassTheme(content: @Composable () -> Unit) {
    val appleLightScheme = lightColorScheme(
        primary = AppleGlassColors.AccentPink,
        onPrimary = Color.White,
        primaryContainer = Color(0xFFFFE5EC),
        onPrimaryContainer = Color(0xFF9E1132),
        secondary = AppleGlassColors.AccentBlue,
        onSecondary = Color.White,
        secondaryContainer = Color(0xFFE0F0FF),
        onSecondaryContainer = Color(0xFF004085),
        background = AppleGlassColors.BgBase,
        onBackground = AppleGlassColors.TextPrimary,
        surface = Color.White,
        onSurface = AppleGlassColors.TextPrimary,
        surfaceVariant = Color(0xFFEFF3F9),
        onSurfaceVariant = AppleGlassColors.TextSecondary,
        outline = Color(0xFFCBD5E1),
    )
    MaterialTheme(
        colorScheme = appleLightScheme,
        content = content,
    )
}
