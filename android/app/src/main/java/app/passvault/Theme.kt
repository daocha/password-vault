package app.passvault

import android.app.Activity
import androidx.annotation.StringRes
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

enum class ThemeMode(val label: String, @StringRes val labelRes: Int) {
    system("System", R.string.seed_theme_system), light("Light", R.string.seed_theme_light), dark("Dark", R.string.seed_theme_dark)
}

private val LightColors = lightColorScheme(
    primary = Color(0xFF244E87), onPrimary = Color.White, primaryContainer = Color(0xFFD6E3FF), onPrimaryContainer = Color(0xFF001B3D),
    secondary = Color(0xFF555F71), onSecondary = Color.White, secondaryContainer = Color(0xFFD9E3F8), onSecondaryContainer = Color(0xFF121C2B),
    tertiary = Color(0xFF3C6939), onTertiary = Color.White, tertiaryContainer = Color(0xFFBCF0B4), onTertiaryContainer = Color(0xFF002204),
    background = Color(0xFFF8F9FF), onBackground = Color(0xFF191C20), surface = Color(0xFFF8F9FF), onSurface = Color(0xFF191C20),
    surfaceVariant = Color(0xFFE0E2EC), onSurfaceVariant = Color(0xFF44474E),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF2F3FA), surfaceContainer = Color(0xFFECEEF4),
    surfaceContainerHigh = Color(0xFFE6E8EE), surfaceContainerHighest = Color(0xFFE1E2E9),
    outline = Color(0xFF74777F), outlineVariant = Color(0xFFC4C6D0), error = Color(0xFFBA1A1A), onError = Color.White,
    errorContainer = Color(0xFFFFDAD6), onErrorContainer = Color(0xFF410002), inverseSurface = Color(0xFF2E3036), inverseOnSurface = Color(0xFFEFF0F7),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFA9C7FF), onPrimary = Color(0xFF0A305F), primaryContainer = Color(0xFF284777), onPrimaryContainer = Color(0xFFD6E3FF),
    secondary = Color(0xFFBDC7DC), onSecondary = Color(0xFF273141), secondaryContainer = Color(0xFF3E4759), onSecondaryContainer = Color(0xFFD9E3F8),
    tertiary = Color(0xFFA1D39A), onTertiary = Color(0xFF0A390F), tertiaryContainer = Color(0xFF245024), onTertiaryContainer = Color(0xFFBCF0B4),
    background = Color(0xFF111318), onBackground = Color(0xFFE2E2E9), surface = Color(0xFF111318), onSurface = Color(0xFFE2E2E9),
    surfaceVariant = Color(0xFF44474E), onSurfaceVariant = Color(0xFFC4C6D0),
    surfaceContainerLowest = Color(0xFF0C0E13), surfaceContainerLow = Color(0xFF191C20), surfaceContainer = Color(0xFF1D2024),
    surfaceContainerHigh = Color(0xFF282A2F), surfaceContainerHighest = Color(0xFF33353A),
    outline = Color(0xFF8E9099), outlineVariant = Color(0xFF44474E), error = Color(0xFFFFB4AB), onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A), onErrorContainer = Color(0xFFFFDAD6), inverseSurface = Color(0xFFE2E2E9), inverseOnSurface = Color(0xFF2E3036),
)

@Composable
fun PassVaultTheme(mode: ThemeMode, content: @Composable () -> Unit) {
    val dark = when (mode) { ThemeMode.system -> isSystemInDarkTheme(); ThemeMode.light -> false; ThemeMode.dark -> true }
    val view = LocalView.current
    if (!view.isInEditMode) SideEffect {
        val window = (view.context as Activity).window
        WindowCompat.getInsetsController(window, view).apply { isAppearanceLightStatusBars = !dark; isAppearanceLightNavigationBars = !dark }
    }
    MaterialTheme(colorScheme = if (dark) DarkColors else LightColors, content = content)
}

/** Dialogs, sheets and popups get their own window: give it the activity's autofill, content-capture and tapjacking protection. */
@androidx.compose.runtime.Composable
fun HardenWindow() {
    val view = androidx.compose.ui.platform.LocalView.current
    androidx.compose.runtime.DisposableEffect(view) {
        val root = view.rootView
        root.importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        root.importantForContentCapture = android.view.View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
        root.filterTouchesWhenObscured = true
        onDispose {}
    }
}
