package app.passvault

import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@StringRes private fun scoreLabel(score: Int) = when { score >= 90 -> R.string.health_excellent; score >= 70 -> R.string.health_good; score >= 50 -> R.string.health_fair; else -> R.string.health_poor }

/** The report's groups, in the order shown. */
enum class HealthSection { reused, weak, old, expiring, twoFactor }

/**
 * The vault health report. Everything is computed from the unlocked records in memory; nothing is sent anywhere.
 *
 * Every group starts collapsed, as a line with its count; [open] holds the keys of the groups (and of the "shared by" sets of reused
 * passwords) the user opened. The caller keeps it, with [listState], so an entry opened from here comes back to the same view. With
 * [focus] the list first scrolls to that group (the caller opens it), then calls [onFocused].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HealthScreen(records: List<VaultRecord>, open: Set<String>, onToggle: (String) -> Unit, listState: LazyListState, focus: HealthSection?, onFocused: () -> Unit,
                 onBack: () -> Unit, onOpen: (VaultRecord) -> Unit) {
    val report = remember(records) { VaultHealth.check(records) }
    val allGood = report.problemCount == 0 && report.noTwoFactor.isEmpty() && report.checked > 0
    val shown = listOfNotNull(HealthSection.reused.takeIf { report.reused.isNotEmpty() }, HealthSection.weak.takeIf { report.weak.isNotEmpty() },
        HealthSection.old.takeIf { report.old.isNotEmpty() }, HealthSection.expiring.takeIf { report.expiring.isNotEmpty() }, HealthSection.twoFactor.takeIf { report.noTwoFactor.isNotEmpty() })
    LaunchedEffect(focus) {
        // The privacy note and the score come first.
        if (focus != null) { shown.indexOf(focus).takeIf { it >= 0 }?.let { listState.scrollToItem(2 + (if (allGood) 1 else 0) + it) }; onFocused() }
    }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = { Text(stringResource(R.string.health_title)) }, navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.main_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        LazyColumn(Modifier.padding(padding), state = listState, contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { PrivacyNote() }
            item { ScoreCard(report) }
            if (allGood) item {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.CheckCircle, null, tint = MaterialTheme.colorScheme.primary); Text(stringResource(R.string.health_all_good), Modifier.padding(start = 12.dp))
                }
            }
            for (section in shown) {
                val expanded = section.name in open
                val toggle = { onToggle(section.name) }
                when (section) {
                    HealthSection.reused -> section(Icons.Outlined.ContentCopy, R.string.health_reused, R.string.health_reused_body, report.reused.size, expanded, toggle) {
                        report.reused.forEachIndexed { i, group ->
                            if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                            // Each password shared by several entries is its own set, one line until opened.
                            val key = "reused:" + group.first().field.id; val setOpen = key in open
                            Row(Modifier.fillMaxWidth().clickable(onClickLabel = stringResource(if (setOpen) R.string.health_collapse else R.string.health_expand)) { onToggle(key) }
                                .padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = if (setOpen) 4.dp else 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(stringResource(R.string.health_reused_group, group.size), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.error)
                                    if (!setOpen) Text(group.joinToString(", ") { it.record.name }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                Icon(if (setOpen) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (setOpen) group.forEach { p -> IssueRow(p.record, p.field.displayName, onOpen) }
                        }
                    }
                    HealthSection.weak -> section(Icons.Outlined.GppMaybe, R.string.health_weak, R.string.health_weak_body, report.weak.size, expanded, toggle) {
                        report.weak.forEach { (p, score) -> IssueRow(p.record, p.field.displayName + " · " + stringResource(if (score == 0) R.string.health_very_weak else R.string.health_weak_label), onOpen) }
                    }
                    HealthSection.old -> section(Icons.Outlined.History, R.string.health_old, R.string.health_old_body, report.old.size, expanded, toggle) {
                        report.old.forEach { (p, since) -> IssueRow(p.record, p.field.displayName + " · " + stringResource(R.string.health_old_since, formatDate(since)), onOpen) }
                    }
                    HealthSection.expiring -> section(Icons.Outlined.Event, R.string.health_expiring, R.string.health_expiring_body, report.expiring.size, expanded, toggle) {
                        report.expiring.forEach { r -> val date = r.expiryDate!!; IssueRow(r, stringResource(if (r.expiryState() == ExpiryState.expired) R.string.rec_expired_on else R.string.rec_expires_on, formatDate(date)), onOpen) }
                    }
                    HealthSection.twoFactor -> section(Icons.Outlined.Pin, R.string.health_2fa, R.string.health_2fa_body, report.noTwoFactor.size, expanded, toggle, advice = true) {
                        report.noTwoFactor.forEach { r -> IssueRow(r, r.website.ifBlank { r.fields.firstOrNull { it.kind == FieldKind.username }?.value.orEmpty() }, onOpen) }
                    }
                }
            }
        }
    }
}

/** The on-device disclaimer shown at the top of the report. */
@Composable
private fun PrivacyNote() {
    Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer, contentColor = MaterialTheme.colorScheme.onSecondaryContainer)) {
        Row(Modifier.padding(16.dp)) {
            Icon(Icons.Outlined.PhonelinkLock, null)
            Column(Modifier.padding(start = 12.dp)) {
                Text(stringResource(R.string.health_private_title), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Text(stringResource(R.string.health_private_body), Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun ScoreCard(report: HealthReport) {
    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        val score = report.score
        Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(contentAlignment = Alignment.Center) {
                CircularProgressIndicator(progress = { (score ?: 0) / 100f }, Modifier.size(72.dp), color = if ((score ?: 100) >= 70) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error, strokeWidth = 6.dp, trackColor = MaterialTheme.colorScheme.surfaceContainerHighest)
                Text(score?.toString() ?: "—", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            }
            Column(Modifier.padding(start = 20.dp)) {
                Text(stringResource(R.string.health_score_label), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(if (score == null) stringResource(R.string.health_nothing) else stringResource(scoreLabel(score)), style = MaterialTheme.typography.titleMedium)
                if (report.checked > 0) Text(stringResource(R.string.health_checked, report.checked), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** A group of the report: its header (tap to open or close it) and, when [expanded], its entries. */
private fun LazyListScope.section(icon: ImageVector, @StringRes title: Int, @StringRes body: Int, count: Int, expanded: Boolean, onToggle: () -> Unit, advice: Boolean = false,
                                  content: @Composable ColumnScope.() -> Unit) {
    item(key = title) {
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
            Column(Modifier.padding(vertical = 8.dp)) {
                Row(Modifier.fillMaxWidth().clickable(onClickLabel = stringResource(if (expanded) R.string.health_collapse else R.string.health_expand), onClick = onToggle)
                    .padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconBadge(icon, 40.dp, if (advice) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.errorContainer, if (advice) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onErrorContainer)
                    Column(Modifier.weight(1f).padding(start = 12.dp)) {
                        Text(stringResource(title) + "  ($count)", style = MaterialTheme.typography.titleMedium)
                        Text(stringResource(body), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, Modifier.padding(start = 8.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (expanded) content()
            }
        }
    }
}

@Composable
private fun IssueRow(record: VaultRecord, detail: String, onOpen: (VaultRecord) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onOpen(record) }.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        RecordAvatar(record, 36.dp)
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(record.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (detail.isNotBlank()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
