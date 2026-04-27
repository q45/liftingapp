package com.wasatchcode.lifting.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import android.app.Activity

/**
 * Forced dark theme matching the iOS app. We feed our color tokens
 * into Material 3's color scheme so any Material 3 component (TextField,
 * Slider, etc.) inherits the brand surfaces without per-component
 * tweaks. Components that need exact control (custom buttons,
 * SectionLabel) read AppColors directly.
 *
 * The iOS app forces .preferredColorScheme(.dark); we do the
 * equivalent here by ignoring `isSystemInDarkTheme()` and always
 * using the dark scheme. If users ever ask for a light mode that
 * branch goes here.
 */
private val LiftingDarkColorScheme = darkColorScheme(
    primary             = AppColors.Accent,
    onPrimary           = Color.Black, // text on yellow buttons
    primaryContainer    = AppColors.Accent,
    onPrimaryContainer  = Color.Black,

    secondary           = AppColors.Accent,
    onSecondary         = Color.Black,

    background          = AppColors.Bg,
    onBackground        = AppColors.White,

    surface             = AppColors.Card,
    onSurface           = AppColors.White,
    surfaceVariant      = AppColors.Card2,
    onSurfaceVariant    = AppColors.Muted,

    outline             = AppColors.Border,
    outlineVariant      = AppColors.Border,

    error               = AppColors.Red,
    onError             = AppColors.White,
)

@Composable
fun LiftingTheme(
    @Suppress("UNUSED_PARAMETER") darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colorScheme = LiftingDarkColorScheme

    // Sync system bars with the app surface so nothing flashes white.
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = AppColors.Bg.toArgb()
            window.navigationBarColor = AppColors.Bg.toArgb()
            WindowCompat.getInsetsController(window, view)
                .isAppearanceLightStatusBars = false
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography  = LiftingTypography,
        content     = content,
    )
}
