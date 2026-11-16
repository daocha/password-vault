package app.passvault

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.VerticalSplit
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * The vault list with the open entry beside it, as iOS shows it on an iPad and on an iPhone in landscape. A narrow window
 * (a phone held upright, a folded phone) opens the entry full screen over the list instead, as before.
 */
internal object EntrySplit {
    /** Material's medium window width: tablets, unfolded foldables, and nearly every phone turned sideways. */
    const val WIDE_DP = 600
    /** A small phone in landscape, whose window can be a little narrower than [WIDE_DP]. */
    const val LANDSCAPE_DP = 560
    const val LIST_MIN_DP = 280f
    const val LIST_MAX_DP = 420f

    /** Whether a window this size shows the list and the open entry side by side. */
    fun isWide(widthDp: Int, heightDp: Int) = widthDp >= WIDE_DP || (widthDp > heightDp && widthDp >= LANDSCAPE_DP)
    fun isWide(configuration: android.content.res.Configuration) = isWide(configuration.screenWidthDp, configuration.screenHeightDp)
    /** Material's compact window height: a phone in landscape. The list then gives its tabs to the pane beside it. */
    const val SHORT_DP = 480
    fun isShort(heightDp: Int) = heightDp < SHORT_DP
    fun isShort(configuration: android.content.res.Configuration) = isShort(configuration.screenHeightDp)
    /** Whether the tabs go above the entry beside the list rather than above the list. Matches iOS's tabsInSidePane. */
    fun tabsBeside(widthDp: Int, heightDp: Int) = isWide(widthDp, heightDp) && isShort(heightDp)

    /** The list's share of the width: a little under half, so the entry beside it gets the larger part. */
    fun listWidthDp(widthDp: Float) = (widthDp * 0.45f).coerceIn(LIST_MIN_DP, LIST_MAX_DP).coerceAtMost(widthDp)

    /**
     * The open entry after the vault's records changed. Beside the list, the list's own actions (a group set for selected
     * entries, a delete, a 2FA reorder) can change or remove the entry shown, so its details follow the vault, and close
     * once it is gone. An open editor keeps its own copy: it may be a new entry, not in the vault yet.
     */
    fun refreshed(viewing: VaultRecord?, editing: Boolean, records: List<VaultRecord>): VaultRecord? =
        if (viewing == null || editing) viewing else records.firstOrNull { it.id == viewing.id }

    /**
     * Whether Back belongs to the list (clearing its selection) rather than to the open entry. The list is in front when no
     * entry is open, or when the entry is beside it and only showing its details; an editor is always in front.
     */
    fun listInFront(entryOpen: Boolean, editing: Boolean, split: Boolean) = !entryOpen || (split && !editing)
}

/**
 * The vault list and the open entry: side by side when both are shown, otherwise whichever one is, filling the window.
 * Both always sit at the same place in the composition, and only their widths change, so turning or folding the phone
 * keeps everything they hold (unsaved edits, an open dialog, a 2FA reorder, the camera preview of a QR scan).
 * While the entry beside the list is being edited ([listLocked]) the list stays in view but dimmed and out of reach (touch,
 * TalkBack and keyboard focus), so nothing beside the editor can change or delete the entry under it or open another one
 * over unsaved changes.
 */
@Composable
internal fun EntrySplitLayout(showList: Boolean, showPane: Boolean, listLocked: Boolean, list: @Composable () -> Unit, pane: @Composable () -> Unit, modifier: Modifier = Modifier) {
    val split = showList && showPane
    val locked = split && listLocked
    Layout(content = {
        Box(if (split) Modifier.testTag(SPLIT_LIST) else Modifier) {
            Box(if (locked) Modifier.clearAndSetSemantics {}.focusProperties { onEnter = { cancelFocusChange() } }.focusGroup() else Modifier) { if (showList) list() }
            if (locked) Box(Modifier.matchParentSize().testTag(SPLIT_LIST_LOCKED)
                .background(MaterialTheme.colorScheme.scrim.copy(alpha = .32f))
                .pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } } })
        }
        VerticalDivider()
        Box(if (split) Modifier.testTag(SPLIT_PANE) else Modifier) { if (showPane) pane() }
    }, modifier) { measurables, constraints ->
        val width = constraints.maxWidth; val height = constraints.maxHeight
        val listWidth = when { split -> (EntrySplit.listWidthDp(width / density) * density).roundToInt().coerceIn(0, width); showList -> width; else -> 0 }
        val divider = measurables[1].measure(if (split) Constraints(maxWidth = width - listWidth, minHeight = height, maxHeight = height) else Constraints.fixed(0, height))
        val paneWidth = (width - listWidth - divider.width).coerceAtLeast(0)
        val listPlaceable = measurables[0].measure(Constraints.fixed(listWidth, height))
        val panePlaceable = measurables[2].measure(Constraints.fixed(paneWidth, height))
        layout(width, height) {
            if (showList) listPlaceable.place(0, 0)
            if (split) divider.place(listWidth, 0)
            if (showPane) panePlaceable.place(listWidth + divider.width, 0)
        }
    }
}

/** An entry's details close with X beside the list, as on iOS, and go back with an arrow when they fill the window. */
@Composable
internal fun CloseOrBack(inPane: Boolean, backLabel: String, onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        if (inPane) Icon(Icons.Default.Close, stringResource(R.string.main_close)) else Icon(Icons.AutoMirrored.Filled.ArrowBack, backLabel)
    }
}

/** The right-hand side before any entry is open; [body] says where to pick one (the list, or the health report). */
@Composable
internal fun NoEntrySelected(@StringRes body: Int = R.string.main_no_entry_selected_body) {
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center) {
        IconBadge(Icons.Outlined.VerticalSplit, 72.dp)
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.main_no_entry_selected), style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Text(stringResource(body), Modifier.fillMaxWidth().padding(top = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

internal const val SPLIT_LIST = "split-list"
internal const val SPLIT_LIST_LOCKED = "split-list-locked"
internal const val SPLIT_PANE = "split-pane"
internal const val PANE_TABS = "pane-tabs"
