package app.passvault

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString

enum class ClipboardClear(val label: String, val millis: Long?, @StringRes val labelRes: Int) {
    s30("30 seconds", 30_000, R.string.seed_clip_30s), m1("1 minute", 60_000, R.string.seed_clip_1m), m2("2 minutes", 120_000, R.string.seed_clip_2m), m5("5 minutes", 300_000, R.string.seed_clip_5m),
    m10("10 minutes", 600_000, R.string.seed_clip_10m), m15("15 minutes", 900_000, R.string.seed_clip_15m), never("Never", null, R.string.seed_clip_never)
}

/**
 * When [block] is set, copy and cut from text fields become no-ops; paste into the app still works.
 * Otherwise copied text goes through [onCopy] (sensitive flag and auto-clear) instead of straight to the system clipboard.
 */
@Suppress("DEPRECATION")
@Composable
fun BlockTextCopy(block: Boolean, onCopy: ((String) -> Unit)? = null, content: @Composable () -> Unit) {
    if (!block && onCopy == null) { content(); return }
    val clipboard = LocalClipboard.current; val manager = LocalClipboardManager.current
    val send by rememberUpdatedState { text: String? -> if (!block && !text.isNullOrEmpty()) onCopy?.invoke(text) }
    val guarded = remember(clipboard) { object : Clipboard by clipboard { override suspend fun setClipEntry(clipEntry: ClipEntry?) { send(clipEntry?.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()) } } }
    val guardedManager = remember(manager) { object : ClipboardManager by manager { override fun setText(annotatedString: AnnotatedString) { send(annotatedString.text) }; override fun setClip(clipEntry: ClipEntry?) { send(clipEntry?.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()) } } }
    CompositionLocalProvider(LocalClipboard provides guarded, LocalClipboardManager provides guardedManager, content = content)
}
