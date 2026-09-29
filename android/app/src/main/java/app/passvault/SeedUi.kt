package app.passvault

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import java.time.Instant

@Composable
fun SeedWarning() {
    Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer, contentColor = MaterialTheme.colorScheme.onErrorContainer), border = BorderStroke(1.dp, MaterialTheme.colorScheme.error)) {
        Row(Modifier.padding(16.dp)) {
            Icon(Icons.Default.Warning, null, tint = MaterialTheme.colorScheme.error)
            Column(Modifier.padding(start = 12.dp)) {
                Text(stringResource(R.string.seed_high_risk_title), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Text(stringResource(R.string.seed_high_risk_body), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** Numbered words in a 3-column grid. */
@Composable
fun SeedWordGrid(words: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        words.chunked(3).forEachIndexed { row, chunk ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                chunk.forEachIndexed { col, word ->
                    Surface(Modifier.weight(1f), shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest) {
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("${row * 3 + col + 1}", Modifier.width(22.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(word, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace, maxLines = 1)
                        }
                    }
                }
                repeat(3 - chunk.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeedDetail(record: VaultRecord, onBack: () -> Unit, onEdit: () -> Unit, onDelete: () -> Unit, onToggleFavorite: () -> Unit) {
    var shown by remember(record.id) { mutableStateOf(false) }; var passphraseShown by remember(record.id) { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }; var deleting by remember { mutableStateOf(false) }
    val privateKey = record.privateKey; val words = record.seedWords; val problem = remember(words) { Bip39.problem(words) }
    val passphrase = record.fields.firstOrNull { it.label == SEED_PASSPHRASE_LABEL }?.value.orEmpty()
    val notes = record.fields.firstOrNull { it.kind == FieldKind.note }?.value.orEmpty()
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = {}, navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.seed_back)) } },
            actions = {
                IconButton(onClick = onToggleFavorite) { Icon(if (record.favorite) Icons.Default.Star else Icons.Outlined.StarOutline, stringResource(if (record.favorite) R.string.seed_remove_favorite else R.string.seed_add_favorite), tint = if (record.favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                IconButton(onClick = onEdit) { Icon(Icons.Outlined.Edit, stringResource(R.string.seed_edit)) }
                Box { IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, stringResource(R.string.seed_more)) }
                    DropdownMenu(menu, { menu = false }) { DropdownMenuItem(text = { Text(stringResource(R.string.seed_delete_menu)) }, leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = { menu = false; deleting = true }) } }
            }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    IconBadge(Icons.Outlined.AccountBalanceWallet, 72.dp, MaterialTheme.colorScheme.tertiaryContainer, MaterialTheme.colorScheme.onTertiaryContainer)
                    Text(record.name, Modifier.padding(top = 12.dp), style = MaterialTheme.typography.headlineSmall)
                    AssistChip(onClick = {}, label = { Text(if (privateKey != null) stringResource(R.string.seed_chip_private_key, PrivateKey.format(privateKey).text()) else if (problem == null) stringResource(R.string.seed_chip_bip39, words.size) else stringResource(R.string.seed_chip_invalid)) }, leadingIcon = { Icon(if (privateKey != null || problem == null) Icons.Outlined.Verified else Icons.Outlined.ErrorOutline, null, Modifier.size(18.dp)) }, modifier = Modifier.padding(top = 8.dp))
                }
            }
            item {
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(displayLabel(if (privateKey != null) PRIVATE_KEY_LABEL else SEED_LABEL), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                            FilledTonalButton(onClick = { shown = !shown }) { Icon(if (shown) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(if (shown) R.string.seed_hide else if (privateKey != null) R.string.seed_show_key else R.string.seed_show_words)) }
                        }
                        if (shown && privateKey != null) Text(privateKey, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
                        else if (shown) SeedWordGrid(words)
                        else Text(stringResource(if (privateKey != null) R.string.seed_hidden_key else R.string.seed_hidden_words), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (passphrase.isNotEmpty()) item {
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Row(Modifier.padding(start = 16.dp, end = 4.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconBadge(Icons.Outlined.Password)
                        Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                            Text(displayLabel(SEED_PASSPHRASE_LABEL), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(if (passphraseShown) passphrase else "••••••••••", style = MaterialTheme.typography.bodyLarge, fontFamily = if (passphraseShown) FontFamily.Monospace else null)
                        }
                        IconButton(onClick = { passphraseShown = !passphraseShown }) { Icon(if (passphraseShown) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, stringResource(if (passphraseShown) R.string.seed_hide else R.string.seed_reveal)) }
                    }
                }
            }
            if (notes.isNotBlank()) item {
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Row(Modifier.padding(16.dp)) { IconBadge(FieldKind.note.icon); Column(Modifier.padding(start = 16.dp)) { Text(stringResource(R.string.seed_notes), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant); Text(notes) } }
                }
            }
            item { Text(stringResource(R.string.seed_never_copied), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center) }
        }
    }
    if (deleting) AlertDialog(onDismissRequest = { deleting = false }, icon = { Icon(Icons.Outlined.Delete, null) }, title = { Text(stringResource(if (privateKey != null) R.string.seed_delete_key_title else R.string.seed_delete_phrase_title)) }, text = { HardenWindow(); Text(stringResource(if (privateKey != null) R.string.seed_delete_key_body else R.string.seed_delete_words_body, record.name)) },
        confirmButton = { TextButton(onClick = { deleting = false; onDelete() }) { Text(stringResource(R.string.seed_delete)) } }, dismissButton = { TextButton(onClick = { deleting = false }) { Text(stringResource(R.string.seed_cancel)) } })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeedEditor(initial: VaultRecord, isNew: Boolean, onCancel: () -> Unit, onSave: (VaultRecord) -> Unit) {
    var name by remember { mutableStateOf(initial.name) }; var favorite by remember { mutableStateOf(initial.favorite) }
    var keyOnly by remember { mutableStateOf(initial.privateKey != null) }; var privateKey by remember { mutableStateOf(initial.privateKey.orEmpty()) }; var keyShown by remember { mutableStateOf(false) }
    var generate by remember { mutableStateOf(isNew) }; var count by remember { mutableIntStateOf(initial.seedWords.size.takeIf { it in Bip39.WORD_COUNTS } ?: 12) }
    var generated by remember { mutableStateOf(if (isNew) Bip39.generate(12) else emptyList()) }
    var typed by remember { mutableStateOf(TextFieldValue(initial.seedWords.joinToString(" "))) }
    var passphrase by remember { mutableStateOf(initial.fields.firstOrNull { it.label == SEED_PASSPHRASE_LABEL }?.value.orEmpty()) }; var passphraseShown by remember { mutableStateOf(false) }
    var notes by remember { mutableStateOf(initial.fields.firstOrNull { it.kind == FieldKind.note }?.value.orEmpty()) }
    var confirmedWritten by remember { mutableStateOf(!isNew) }
    val words = if (generate) generated else Bip39.split(typed.text)
    val problem = if (keyOnly) PrivateKey.problem(privateKey) else remember(words) { Bip39.problem(words) }
    // The word being typed is the text after the last space, provided the cursor sits at the end.
    val partial = typed.text.takeIf { typed.selection.end == it.length && !it.endsWith(" ") }?.substringAfterLast(' ')?.lowercase().orEmpty()
    val suggestions = remember(partial) { if (Bip39.isWord(partial) && Bip39.suggestions(partial, 2).size == 1) emptyList() else Bip39.suggestions(partial) }
    fun accept(word: String) { val text = typed.text.substring(0, typed.text.length - partial.length) + word + " "; typed = TextFieldValue(text, TextRange(text.length)) }
    fun save() {
        val fields = listOf(if (keyOnly) VaultField(kind = FieldKind.password, label = PRIVATE_KEY_LABEL, value = privateKey.trim()) else VaultField(kind = FieldKind.password, label = SEED_LABEL, value = words.joinToString(" "))) +
            (if (passphrase.isNotEmpty() && !keyOnly) listOf(VaultField(kind = FieldKind.password, label = SEED_PASSPHRASE_LABEL, value = passphrase)) else emptyList()) +
            (if (notes.isNotBlank()) listOf(VaultField(kind = FieldKind.note, label = "Notes", value = notes)) else emptyList()) +
            // Keep any other fields (e.g. from a backup made elsewhere) instead of silently dropping them.
            initial.fields.filter { it.label !in listOf(SEED_LABEL, PRIVATE_KEY_LABEL, SEED_PASSPHRASE_LABEL) && it !== initial.fields.firstOrNull { f -> f.kind == FieldKind.note } }
        onSave(initial.copy(name = name.trim(), favorite = favorite, type = RecordType.seed, fields = fields, updatedAt = Instant.now().toString()))
    }
    // Seed words must never reach the clipboard, even when copying is allowed elsewhere.
    BlockTextCopy(true) {
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = { Text(stringResource(if (keyOnly) (if (isNew) R.string.seed_title_new_key else R.string.seed_title_edit_key) else if (isNew) R.string.seed_title_new_phrase else R.string.seed_title_edit_phrase)) }, navigationIcon = { IconButton(onClick = onCancel) { Icon(Icons.Default.Close, stringResource(R.string.seed_discard)) } },
            actions = {
                IconButton(onClick = { favorite = !favorite }) { Icon(if (favorite) Icons.Default.Star else Icons.Outlined.StarOutline, stringResource(if (favorite) R.string.seed_remove_favorite else R.string.seed_add_favorite), tint = if (favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                Button(onClick = ::save, enabled = name.isNotBlank() && problem == null && confirmedWritten, modifier = Modifier.padding(end = 8.dp)) { Text(stringResource(R.string.seed_save)) }
            }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { SeedWarning() }
            item { OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.seed_wallet_name)) }, leadingIcon = { Icon(Icons.Outlined.AccountBalanceWallet, null) }, singleLine = true, shape = RoundedCornerShape(12.dp)) }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SegmentedButton(generate && !keyOnly, { keyOnly = false; generate = true; if (generated.size != count) generated = Bip39.generate(count); confirmedWritten = false }, SegmentedButtonDefaults.itemShape(0, 3)) { Text(stringResource(R.string.seed_mode_generate)) }
                    SegmentedButton(!generate && !keyOnly, { keyOnly = false; generate = false; confirmedWritten = true }, SegmentedButtonDefaults.itemShape(1, 3)) { Text(stringResource(R.string.seed_mode_enter)) }
                    SegmentedButton(keyOnly, { keyOnly = true; confirmedWritten = true }, SegmentedButtonDefaults.itemShape(2, 3)) { Text(stringResource(R.string.seed_mode_key)) }
                }
            }
            if (keyOnly) {
                item {
                    OutlinedTextField(privateKey, { privateKey = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.seed_mode_key)) }, singleLine = true, shape = RoundedCornerShape(12.dp),
                        textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                        supportingText = { Text(if (privateKey.isBlank()) stringResource(R.string.seed_key_hint) else (problem ?: PrivateKey.format(privateKey)).text(), color = if (privateKey.isNotBlank() && problem != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant) },
                        visualTransformation = if (keyShown) VisualTransformation.None else PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                        trailingIcon = { IconButton(onClick = { keyShown = !keyShown }) { Icon(if (keyShown) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, stringResource(if (keyShown) R.string.seed_hide else R.string.seed_reveal)) } })
                }
            } else if (generate) {
                item {
                    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                                    Bip39.WORD_COUNTS.forEachIndexed { i, n -> SegmentedButton(count == n, { count = n; generated = Bip39.generate(n); confirmedWritten = false }, SegmentedButtonDefaults.itemShape(i, 2)) { Text(stringResource(R.string.seed_word_count, n)) } }
                                }
                                IconButton(onClick = { generated = Bip39.generate(count); confirmedWritten = false }) { Icon(Icons.Outlined.Refresh, stringResource(R.string.seed_generate_another_phrase)) }
                            }
                            SeedWordGrid(generated)
                            CheckRow(confirmedWritten, { confirmedWritten = it }) { Text(stringResource(R.string.seed_confirm_written), style = MaterialTheme.typography.bodyMedium) }
                        }
                    }
                }
            } else {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(typed, { typed = it.copy(text = it.text.lowercase()) }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.seed_words_field)) }, minLines = 3, shape = RoundedCornerShape(12.dp),
                            textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                            // Password keyboard type keeps IMEs from learning or suggesting the words.
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                            supportingText = { Text(if (words.isEmpty()) stringResource(R.string.seed_words_hint) else problem?.text() ?: stringResource(R.string.seed_valid_phrase, words.size), color = if (words.isNotEmpty() && problem == null) MaterialTheme.colorScheme.tertiary else if (problem != null && words.size in Bip39.WORD_COUNTS) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant) })
                        if (suggestions.isNotEmpty()) LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(suggestions) { word -> SuggestionChip(onClick = { accept(word) }, label = { Text(word, fontFamily = FontFamily.Monospace) }) } }
                        else if (partial.isNotEmpty() && !Bip39.isWord(partial)) Text(stringResource(R.string.seed_no_word, partial), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                }
            }
            if (!keyOnly) item {
                OutlinedTextField(passphrase, { passphrase = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.seed_passphrase_label)) }, singleLine = true, shape = RoundedCornerShape(12.dp),
                    supportingText = { Text(stringResource(R.string.seed_passphrase_hint)) },
                    visualTransformation = if (passphraseShown) VisualTransformation.None else PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                    trailingIcon = { IconButton(onClick = { passphraseShown = !passphraseShown }) { Icon(if (passphraseShown) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, stringResource(if (passphraseShown) R.string.seed_hide else R.string.seed_reveal)) } })
            }
            item { OutlinedTextField(notes, { notes = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.seed_notes_optional)) }, minLines = 2, shape = RoundedCornerShape(12.dp)) }
        }
    }
    }
}

@Composable
fun UiText.text(): String = stringResource(res, *args.toTypedArray())
