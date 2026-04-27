package com.wasatchcode.lifting.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * App typography. Mirrors the iOS app's reliance on system fonts:
 * we default to FontFamily.Default (Roboto on Android, San Francisco
 * on iOS) and let the bold-weights-on-numbers, medium-on-body,
 * uppercase-on-labels pattern do the work.
 *
 * The iOS code uses .system(size:weight:design:) literals throughout
 * rather than a centralized typography. We do the same here -- this
 * file just gives Material 3 a sensible scale for components that
 * do query MaterialTheme.typography (TextField labels, Snackbar, etc.)
 * Custom views read sp() directly.
 */
val LiftingTypography = Typography(
    headlineLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Black,
        fontSize   = 30.sp,
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Bold,
        fontSize   = 22.sp,
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize   = 16.sp,
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize   = 14.sp,
    ),
    labelMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize   = 11.sp,
        letterSpacing = 0.8.sp,
    ),
)
