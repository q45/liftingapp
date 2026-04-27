package com.wasatchcode.lifting.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * App color tokens. 1:1 mirror of lifting/Theme.swift -- any change
 * to one side should be reflected in the other so the iOS and
 * Android builds feel like the same app.
 *
 * Naming convention deliberately matches the iOS code (`appAccent`,
 * `appCard`, `appMuted`, ...) so reading either codebase doesn't
 * require translation. Kotlin's PascalCase doesn't really apply to
 * top-level vals; we lean on the prefix for that visual cue.
 */
object AppColors {
    // Surfaces
    val Bg          = Color(0xFF0C0C0C) // near-black, not pure black
    val Card        = Color(0xFF181818) // raised card
    val Card2       = Color(0xFF242424) // input fields, secondary surfaces
    val Border      = Color(0xFF2A2A2A) // 1dp hairlines

    // Brand accent
    val Accent      = Color(0xFFF5E642) // electric yellow

    // Text
    val White       = Color(0xFFFFFFFF)
    val Muted       = Color(0xFF999999) // secondary text
    val Muted2      = Color(0xFF999999) // alias for parity with iOS code -- diverged once historically; keep aliased.
    val MutedDeep   = Color(0xFF666666) // tertiary text

    // Status
    val Green       = Color(0xFF4ECB71)
    val Red         = Color(0xFFFF4444)

    // Category dots (used on exercise rows + history charts).
    fun categoryColor(category: String): Color = when (category.lowercase()) {
        "chest"     -> Color(0xFFFF6B6B)
        "back"      -> Color(0xFF4ECDC4)
        "legs"      -> Color(0xFF45B7D1)
        "shoulders" -> Color(0xFF96CEB4)
        "arms"      -> Color(0xFFFFD166)
        "core"      -> Color(0xFFC77DFF)
        else        -> Muted
    }
}
