package com.dineshdevkota.cinevault.ui

import android.content.res.Configuration
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.SurfaceDefaults
import androidx.tv.material3.darkColorScheme
import androidx.compose.material3.MaterialTheme as MobileMaterialTheme
import androidx.compose.material3.darkColorScheme as mobileDarkColorScheme

val Background = Color(0xFF0E0F13)
val SurfaceColor = Color(0xFF1A1C22)
val Accent = Color(0xFFE5A00D)
val SecondaryText = Color(0xFFA7A9B2)
val ErrorText = Color(0xFFFF8A80)

internal val LocalTvLayout = staticCompositionLocalOf { true }

internal fun Configuration.isTelevision(): Boolean =
    uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_TELEVISION

val ScreenPadding
    @Composable get() = if (LocalTvLayout.current) 48.dp else 16.dp

@Composable
fun CineVaultTheme(content: @Composable () -> Unit) {
    val isTv = LocalConfiguration.current.isTelevision()
    MobileMaterialTheme(
        colorScheme = mobileDarkColorScheme(
            primary = Accent,
            onPrimary = Color.Black,
            background = Background,
            surface = SurfaceColor,
            onSurface = Color.White,
            onSurfaceVariant = SecondaryText,
        ),
    ) {
        MaterialTheme(
            colorScheme = darkColorScheme(
                primary = Accent,
                onPrimary = Color.Black,
                background = Background,
                onBackground = Color.White,
                surface = SurfaceColor,
                onSurface = Color.White,
                onSurfaceVariant = SecondaryText,
                border = Accent,
            ),
        ) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                shape = RectangleShape,
                colors = SurfaceDefaults.colors(containerColor = Background, contentColor = Color.White),
            ) {
                CompositionLocalProvider(LocalTvLayout provides isTv) {
                    if (isTv) content() else Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                        content()
                    }
                }
            }
        }
    }
}

fun ComponentActivity.setCineVaultContent(content: @Composable () -> Unit) = setContent {
    CineVaultTheme { FamilyGate(adminOnly = this is NasSetupActivity || this is SourceEditorActivity ||
        this is EditMovieActivity || this is PlaybackSettingsActivity, content = content) }
}
