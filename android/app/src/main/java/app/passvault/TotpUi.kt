package app.passvault

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.zIndex
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import java.time.Instant

/** "123 456", "1234 5678": codes are easier to read and type in two halves. */
fun formatTotpCode(code: String) = if (code.length < 6) code else code.substring(0, code.length / 2) + " " + code.substring(code.length / 2)

/** Wall-clock time, refreshed a few times a second while shown, so codes and countdowns stay current. */
@Composable
fun rememberNowMillis(): Long {
    val now by produceState(System.currentTimeMillis()) { while (true) { value = System.currentTimeMillis(); delay(250) } }
    return now
}

/** Ring that empties as the current code ages, with the seconds left inside; turns to the error color for the last five seconds. */
@Composable
fun TotpCountdown(account: TotpAccount, nowMillis: Long, size: Dp = 32.dp) {
    val remaining = account.remaining(nowMillis / 1000)
    val fraction = ((account.period * 1000 - Math.floorMod(nowMillis, account.period * 1000L)) / (account.period * 1000f)).coerceIn(0f, 1f)
    val urgent = remaining <= 5
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(progress = { fraction }, Modifier.fillMaxSize(), color = if (urgent) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary, trackColor = MaterialTheme.colorScheme.surfaceContainerHighest, strokeWidth = 3.dp)
        Text("$remaining", style = if (size >= 48.dp) MaterialTheme.typography.labelLarge else MaterialTheme.typography.labelSmall, color = if (urgent) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The live code and countdown at the end of a list row; tapping the code copies it when [onCopy] is given. */
@Composable
fun TotpRowCode(account: TotpAccount?, nowMillis: Long, onCopy: ((String) -> Unit)?) {
    if (account == null) { Icon(Icons.Outlined.ErrorOutline, stringResource(R.string.totp_damaged), tint = MaterialTheme.colorScheme.error); return }
    val code = account.code(nowMillis / 1000)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(formatTotpCode(code), Modifier.then(if (onCopy != null) Modifier.clickable(onClickLabel = stringResource(R.string.totp_copy_code)) { onCopy(code) } else Modifier).padding(horizontal = 8.dp, vertical = 4.dp),
            style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, color = if (account.remaining(nowMillis / 1000) <= 5) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
        TotpCountdown(account, nowMillis)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TotpDetail(record: VaultRecord, onCopy: ((String) -> Unit)?, onBack: () -> Unit, onEdit: () -> Unit, onDelete: () -> Unit, onToggleFavorite: () -> Unit) {
    val account = remember(record) { record.totp }
    var keyShown by remember(record.id) { mutableStateOf(false) }; var menu by remember { mutableStateOf(false) }; var deleting by remember { mutableStateOf(false) }
    val notes = record.fields.firstOrNull { it.kind == FieldKind.note }?.value.orEmpty()
    val now = rememberNowMillis()
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = {}, navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.seed_back)) } },
            actions = {
                IconButton(onClick = onToggleFavorite) { Icon(if (record.favorite) Icons.Default.Star else Icons.Outlined.StarOutline, stringResource(if (record.favorite) R.string.seed_remove_favorite else R.string.seed_add_favorite), tint = if (record.favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                IconButton(onClick = onEdit) { Icon(Icons.Outlined.Edit, stringResource(R.string.seed_edit)) }
                Box { IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, stringResource(R.string.seed_more)) }
                    DropdownMenu(menu, { menu = false }) { DropdownMenuItem(text = { Text(stringResource(R.string.totp_delete_menu)) }, leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = { menu = false; deleting = true }) } }
            }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    RecordAvatar(record, 72.dp)
                    Text(record.name, Modifier.padding(top = 12.dp), style = MaterialTheme.typography.headlineSmall)
                    if (!account?.account.isNullOrBlank()) Text(account!!.account, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                }
            }
            item {
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    if (account == null) Text(stringResource(R.string.totp_damaged), Modifier.padding(20.dp), color = MaterialTheme.colorScheme.error)
                    else {
                        val code = account.code(now / 1000)
                        Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(formatTotpCode(code), Modifier.weight(1f), style = MaterialTheme.typography.displaySmall, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold,
                                color = if (account.remaining(now / 1000) <= 5) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                            TotpCountdown(account, now, 48.dp)
                            if (onCopy != null) IconButton(onClick = { onCopy(code) }) { Icon(Icons.Outlined.ContentCopy, stringResource(R.string.totp_copy_code)) }
                        }
                    }
                }
            }
            if (account != null) item {
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Row(Modifier.padding(start = 16.dp, end = 4.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconBadge(Icons.Outlined.Key)
                        Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                            Text(stringResource(R.string.totp_key), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(if (keyShown) account.secretBase32.chunked(4).joinToString(" ") else "••••••••••", style = MaterialTheme.typography.bodyLarge, fontFamily = if (keyShown) FontFamily.Monospace else null)
                            Text(stringResource(R.string.totp_settings_line, account.algorithm, account.digits, account.period), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = { keyShown = !keyShown }) { Icon(if (keyShown) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, stringResource(if (keyShown) R.string.totp_hide_key else R.string.totp_show_key)) }
                    }
                }
            }
            if (notes.isNotBlank()) item {
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Row(Modifier.padding(16.dp)) { IconBadge(FieldKind.note.icon); Column(Modifier.padding(start = 16.dp)) { Text(stringResource(R.string.seed_notes), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant); Text(notes) } }
                }
            }
            item { Text(stringResource(R.string.totp_backup_note), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center) }
        }
    }
    if (deleting) AlertDialog(onDismissRequest = { deleting = false }, icon = { Icon(Icons.Outlined.Delete, null) }, title = { Text(stringResource(R.string.totp_delete_title)) }, text = { HardenWindow(); Text(stringResource(R.string.totp_delete_body, record.name)) },
        confirmButton = { TextButton(onClick = { deleting = false; onDelete() }) { Text(stringResource(R.string.seed_delete)) } }, dismissButton = { TextButton(onClick = { deleting = false }) { Text(stringResource(R.string.seed_cancel)) } })
}

/**
 * Adds or edits an authenticator account: scan its QR code with the camera, read it from a screenshot, or type the setup key.
 * A Google Authenticator export QR holds several accounts and goes to [onMigration] instead of filling the form.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TotpEditor(
    initial: VaultRecord, isNew: Boolean, existing: List<VaultRecord>, owner: LifecycleOwner,
    requestCamera: (onGranted: () -> Unit) -> Unit, pickImage: (onText: (String?) -> Unit) -> Unit,
    onMigration: (Totp.Migration) -> Unit, onCancel: () -> Unit, onSave: (VaultRecord) -> Unit,
) {
    val start = remember { initial.totp }
    var name by remember { mutableStateOf(initial.name) }; var favorite by remember { mutableStateOf(initial.favorite) }
    var issuer by remember { mutableStateOf(start?.issuer.orEmpty()) }
    var account by remember { mutableStateOf(start?.account.orEmpty()) }
    var key by remember { mutableStateOf(start?.secretBase32.orEmpty()) }; var keyShown by remember { mutableStateOf(isNew) }
    var algorithm by remember { mutableStateOf(start?.algorithm ?: "SHA1") }; var digits by remember { mutableIntStateOf(start?.digits ?: 6) }
    var period by remember { mutableStateOf((start?.period ?: 30).toString()) }
    var advanced by remember { mutableStateOf(start != null && (start.algorithm != "SHA1" || start.digits != 6 || start.period != 30)) }
    var notes by remember { mutableStateOf(initial.fields.firstOrNull { it.kind == FieldKind.note }?.value.orEmpty()) }
    var scanning by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<UiText?>(null) }; var noticeError by remember { mutableStateOf(false) }
    val secret = remember(key) { runCatching { Totp.decodeBase32(key) }.getOrNull() }
    val candidate = remember(secret, issuer, name, account, algorithm, digits, period) {
        secret?.let { s -> period.toIntOrNull()?.let { p -> runCatching { TotpAccount(s, issuer.ifBlank { name.trim() }, account.trim(), algorithm, digits, p) }.getOrNull() } }
    }
    val duplicate = remember(secret) { secret?.let { s -> existing.firstOrNull { it.id != initial.id && it.type == RecordType.totp && it.totp?.secret?.contentEquals(s) == true } } }
    fun handle(text: String?) {
        noticeError = true
        when {
            text == null -> notice = UiText(R.string.totp_no_qr)
            Totp.isMigration(text) -> runCatching { Totp.parseMigration(text) }.onSuccess { onMigration(it) }.onFailure { notice = UiText(R.string.totp_not_2fa) }
            text.trim().startsWith("otpauth://hotp", ignoreCase = true) -> notice = UiText(R.string.totp_hotp)
            else -> runCatching { Totp.parseUri(text) }.onSuccess { a ->
                issuer = a.issuer; account = a.account; key = a.secretBase32; algorithm = a.algorithm; digits = a.digits; period = a.period.toString()
                if (name.isBlank() || isNew) name = a.issuer.ifBlank { a.account }
                advanced = a.algorithm != "SHA1" || a.digits != 6 || a.period != 30
                noticeError = false; notice = UiText(R.string.totp_scanned)
            }.onFailure { notice = UiText(R.string.totp_not_2fa) }
        }
    }
    fun save() {
        val acct = candidate ?: return
        val totpField = initial.fields.firstOrNull { it.label == TOTP_LABEL }?.copy(value = acct.uri()) ?: VaultField(kind = FieldKind.password, label = TOTP_LABEL, value = acct.uri())
        val note = initial.fields.firstOrNull { it.kind == FieldKind.note }
        val fields = listOf(totpField) + (if (notes.isNotBlank()) listOf(note?.copy(value = notes) ?: VaultField(kind = FieldKind.note, label = "Notes", value = notes)) else emptyList()) +
            // Keep any other fields (e.g. from a backup made elsewhere) instead of silently dropping them.
            initial.fields.filter { it.label != TOTP_LABEL && it !== note }
        onSave(initial.copy(name = name.trim(), favorite = favorite, type = RecordType.totp, fields = fields, updatedAt = Instant.now().toString()))
    }
    if (scanning) {
        BackHandler { scanning = false }
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            QrScanner(owner, onCode = { scanning = false; handle(it) }, Modifier.fillMaxSize())
            Surface(Modifier.align(Alignment.TopCenter).padding(16.dp), shape = RoundedCornerShape(12.dp), color = Color.Black.copy(alpha = 0.6f), contentColor = Color.White) {
                Text(stringResource(R.string.totp_scan_hint), Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
            }
            Box(Modifier.align(Alignment.Center).size(240.dp).border(androidx.compose.foundation.BorderStroke(3.dp, Color.White), RoundedCornerShape(24.dp)))
            FilledTonalButton(onClick = { scanning = false }, Modifier.align(Alignment.BottomCenter).padding(32.dp)) { Icon(Icons.Default.Close, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.totp_scan_close)) }
        }
        return
    }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = { Text(stringResource(if (isNew) R.string.totp_title_new else R.string.totp_title_edit)) }, navigationIcon = { IconButton(onClick = onCancel) { Icon(Icons.Default.Close, stringResource(R.string.seed_discard)) } },
            actions = {
                IconButton(onClick = { favorite = !favorite }) { Icon(if (favorite) Icons.Default.Star else Icons.Outlined.StarOutline, stringResource(if (favorite) R.string.seed_remove_favorite else R.string.seed_add_favorite), tint = if (favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                Button(onClick = ::save, enabled = name.isNotBlank() && candidate != null, modifier = Modifier.padding(end = 8.dp)) { Text(stringResource(R.string.seed_save)) }
            }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { notice = null; requestCamera { scanning = true } }, Modifier.weight(1f).height(52.dp)) { Icon(Icons.Outlined.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.totp_scan)) }
                    OutlinedButton(onClick = { notice = null; pickImage { handle(it) } }, Modifier.weight(1f).height(52.dp)) { Icon(Icons.Outlined.Image, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.totp_from_image)) }
                }
            }
            notice?.let { n -> item {
                Text(n.text(), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyMedium, color = if (noticeError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.tertiary)
            } }
            duplicate?.let { d -> item { Text(stringResource(R.string.totp_duplicate, d.name), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error) } }
            item { OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.totp_name)) }, leadingIcon = { Icon(Icons.Outlined.Badge, null) }, singleLine = true, shape = RoundedCornerShape(12.dp)) }
            item { OutlinedTextField(account, { account = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.totp_account)) }, leadingIcon = { Icon(Icons.Outlined.Person, null) }, singleLine = true, shape = RoundedCornerShape(12.dp), keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Email)) }
            item {
                OutlinedTextField(key, { key = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.totp_key)) }, leadingIcon = { Icon(Icons.Outlined.Key, null) }, singleLine = true, shape = RoundedCornerShape(12.dp),
                    textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                    supportingText = { Text(stringResource(if (key.isNotBlank() && secret == null) R.string.totp_key_invalid else R.string.totp_key_hint), color = if (key.isNotBlank() && secret == null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant) },
                    visualTransformation = if (keyShown) VisualTransformation.None else PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                    trailingIcon = { IconButton(onClick = { keyShown = !keyShown }) { Icon(if (keyShown) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, stringResource(if (keyShown) R.string.totp_hide_key else R.string.totp_show_key)) } })
            }
            item {
                Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Column {
                        Row(Modifier.fillMaxWidth().clickable { advanced = !advanced }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.totp_advanced), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                            Icon(if (advanced) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null)
                        }
                        if (advanced) Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(stringResource(R.string.totp_advanced_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(stringResource(R.string.totp_algorithm), style = MaterialTheme.typography.labelLarge)
                            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) { Totp.ALGORITHMS.forEachIndexed { i, a -> SegmentedButton(algorithm == a, { algorithm = a }, SegmentedButtonDefaults.itemShape(i, Totp.ALGORITHMS.size)) { Text(a) } } }
                            Text(stringResource(R.string.totp_digits), style = MaterialTheme.typography.labelLarge)
                            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) { listOf(6, 7, 8).forEachIndexed { i, d -> SegmentedButton(digits == d, { digits = d }, SegmentedButtonDefaults.itemShape(i, 3)) { Text("$d") } } }
                            OutlinedTextField(period, { v -> period = v.filter { it.isDigit() }.take(3) }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.totp_period)) }, singleLine = true, shape = RoundedCornerShape(12.dp),
                                isError = period.toIntOrNull()?.let { it in 1..300 } != true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                        }
                    }
                }
            }
            candidate?.let { acct -> item {
                val now = rememberNowMillis()
                Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(stringResource(R.string.totp_preview), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(formatTotpCode(acct.code(now / 1000)), style = MaterialTheme.typography.headlineSmall, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.primary, maxLines = 1, overflow = TextOverflow.Clip)
                        }
                        TotpCountdown(acct, now)
                    }
                }
            } }
            item { OutlinedTextField(notes, { notes = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.totp_notes)) }, minLines = 2, shape = RoundedCornerShape(12.dp)) }
            item { Text(stringResource(R.string.totp_backup_note), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center) }
        }
    }
}

/**
 * Lets the user put the 2FA codes in their own order by dragging each row by its handle; screen readers get "Move up" and "Move down" actions instead. Nothing is saved until [onSave], which gets the record ids, top first.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TotpReorder(codes: List<VaultRecord>, onCancel: () -> Unit, onSave: (List<String>) -> Unit) {
    val items = remember { codes.toMutableStateList() }
    val listState = rememberLazyListState()
    val drag = remember { ReorderDrag(listState) { from, to -> items.add(to, items.removeAt(from)) } }
    val haptics = LocalHapticFeedback.current
    val changed = items.map { it.id } != codes.map { it.id }
    BackHandler(onBack = onCancel)
    // While a row is held past an edge, scroll every frame, then let the row take the slot now under it.
    LaunchedEffect(drag) {
        snapshotFlow { drag.index != null }.collectLatest { dragging ->
            while (dragging) { withFrameNanos { }; val step = drag.edgeScroll(); if (step != 0f) { listState.scrollBy(step); drag.drag(0f) } }
        }
    }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = { Text(stringResource(R.string.totp_reorder_title)) }, navigationIcon = { IconButton(onClick = onCancel) { Icon(Icons.Default.Close, stringResource(R.string.seed_discard)) } },
            actions = { Button(onClick = { onSave(items.map { it.id }) }, enabled = changed, modifier = Modifier.padding(end = 8.dp)) { Text(stringResource(R.string.seed_save)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        Column(Modifier.padding(padding).padding(horizontal = 16.dp)) {
            Text(stringResource(R.string.totp_reorder_hint), Modifier.padding(start = 4.dp, bottom = 8.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            // The drag is followed by the list, not the handle: a row that moves to another slot restarts the gestures inside it, which
            // would drop the drag after its first step. A press on a row's handle (the end of the row) drags at once; anywhere else scrolls.
            val handleWidth = with(LocalDensity.current) { HANDLE_ZONE.toPx() }
            LazyColumn(Modifier.fillMaxSize().pointerInput(drag) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    if (down.position.x < size.width - handleWidth || !drag.startAt(down.position.y)) return@awaitEachGesture
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); down.consume()
                    try {
                        while (true) {
                            val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) break
                            drag.drag(change.positionChange().y); change.consume()
                        }
                    } finally { drag.end() }
                }
            }, state = listState, verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 32.dp)) {
                itemsIndexed(items, key = { _, r -> r.id }) { index, record ->
                    val dragging = drag.index == index
                    val up = stringResource(R.string.totp_move_up); val down = stringResource(R.string.totp_move_down)
                    Card(Modifier.fillMaxWidth().testTag(REORDER_ROW)
                        .then(if (dragging) Modifier.zIndex(1f).graphicsLayer { translationY = drag.offset } else Modifier.animateItem())
                        .semantics { customActions = listOfNotNull(
                            if (index > 0) CustomAccessibilityAction(up) { items.add(index - 1, items.removeAt(index)); true } else null,
                            if (index < items.lastIndex) CustomAccessibilityAction(down) { items.add(index + 1, items.removeAt(index)); true } else null) },
                        shape = RoundedCornerShape(16.dp), elevation = CardDefaults.cardElevation(defaultElevation = if (dragging) 6.dp else 0.dp),
                        colors = CardDefaults.cardColors(containerColor = if (dragging) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLow)) {
                        Row(Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            RecordAvatar(record)
                            Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                                Text(record.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                val account = remember(record) { record.totp?.account.orEmpty() }
                                if (account.isNotBlank()) Text(account, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            if (record.favorite) Icon(Icons.Default.Star, stringResource(R.string.main_favorite), Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                            Box(Modifier.size(48.dp).testTag(REORDER_HANDLE), contentAlignment = Alignment.Center) { Icon(Icons.Default.DragHandle, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    }
                }
            }
        }
    }
}

internal const val REORDER_BUTTON = "totp-reorder-button"
/** How far from the end of a row a press grabs it: the 48dp handle and the row's 4dp end padding, with a little room. */
private val HANDLE_ZONE = 56.dp
internal const val REORDER_ROW = "totp-reorder-row"
internal const val REORDER_HANDLE = "totp-reorder-handle"

/**
 * Drag-and-drop for a [LazyColumn] whose items are exactly the list being ordered. The held row is drawn [offset] away from its slot so it
 * stays under the finger (its top is `startOffset + delta` in the viewport, whatever the list scrolls); when its middle crosses another row
 * the two swap through [move]. While the row is held past the top or bottom edge the list keeps scrolling ([edgeScroll], applied every
 * frame by the screen), and the row's slot follows to the edge, so it never scrolls out of view.
 */
private class ReorderDrag(private val list: LazyListState, private val move: (from: Int, to: Int) -> Unit) {
    var index by mutableStateOf<Int?>(null); private set
    private var startOffset = 0; private var delta by mutableFloatStateOf(0f)
    private val current get() = index?.let { i -> list.layoutInfo.visibleItemsInfo.firstOrNull { it.index == i } }
    val offset: Float get() = current?.let { startOffset + delta - it.offset } ?: 0f

    /** Starts dragging the row at [y] (list coordinates); false when there is none. */
    fun startAt(y: Float): Boolean = list.layoutInfo.visibleItemsInfo.firstOrNull { y.toInt() in it.offset..(it.offset + it.size) }?.let { index = it.index; startOffset = it.offset; delta = 0f; true } ?: false

    fun drag(dy: Float) {
        delta += dy
        val item = current ?: return
        val info = list.layoutInfo
        // Past an edge, the row is placed at the edge: the slot there takes it, so it stays among the visible rows as the list scrolls.
        val middle = (startOffset + delta + item.size / 2f).coerceIn(info.viewportStartOffset.toFloat(), info.viewportEndOffset - 1f)
        val target = info.visibleItemsInfo.firstOrNull { it.index != item.index && middle.toInt() in it.offset..(it.offset + it.size) } ?: return
        // Moving the first visible row would scroll the list along with it; keep the list where it is.
        if (item.index == list.firstVisibleItemIndex || target.index == list.firstVisibleItemIndex) list.requestScrollToItem(list.firstVisibleItemIndex, list.firstVisibleItemScrollOffset)
        move(item.index, target.index); index = target.index
    }

    /** Pixels to scroll this frame: faster the further the held row is past an edge, up to an eighth of a row per frame. */
    fun edgeScroll(): Float {
        val item = current ?: return 0f
        val info = list.layoutInfo; val top = startOffset + delta; val bottom = top + item.size
        val past = when { bottom > info.viewportEndOffset -> bottom - info.viewportEndOffset; top < info.viewportStartOffset -> top - info.viewportStartOffset; else -> 0f }
        return (past / item.size).coerceIn(-1f, 1f) * item.size / 8f
    }
    fun end() { index = null; delta = 0f }
}
