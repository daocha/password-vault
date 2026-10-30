package app.passvault

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Settings › File encryption: encrypt files to the vault's age key and decrypt them again. Only the key is in the vault; the files are
 * wherever the user saves them. [backupNeeded]: a key was added since the last encrypted backup.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileEncryptionScreen(keys: List<VaultRecord>, backupNeeded: Boolean, onBack: () -> Unit, onCreateKey: () -> Unit, onImportKey: (String) -> Unit,
    onEncrypt: () -> Unit, onDecrypt: () -> Unit, onCopyPublic: (String) -> Unit, onSharePublic: (String) -> Unit, onOpenKey: (VaultRecord) -> Unit, onBackup: () -> Unit) {
    var creating by remember { mutableStateOf(false) }; var importing by remember { mutableStateOf(false) }
    val current = keys.firstOrNull()
    // Deriving a post-quantum public key expands the ML-KEM key: off the main thread.
    val publicKey by produceState<String?>(null, current?.ageIdentity) { value = current?.ageIdentity?.let { id -> withContext(Dispatchers.Default) { runCatching { Age.parseIdentity(id).recipient.encoded }.getOrNull() } } }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = { Text(stringResource(R.string.files_title)) }, navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.main_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.files_intro), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (current == null) {
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        IconBadge(Icons.Outlined.Key, 56.dp)
                        Text(stringResource(R.string.files_no_key_title), style = MaterialTheme.typography.titleMedium)
                        Text(stringResource(R.string.files_no_key_body), style = MaterialTheme.typography.bodyMedium)
                        Button(onClick = { creating = true }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.files_create_key)) }
                        TextButton(onClick = { importing = true }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.files_import_key)) }
                    }
                }
                return@Column
            }
            if (backupNeeded) AttentionBanner(Icons.Outlined.SaveAlt, stringResource(R.string.files_backup_needed), stringResource(R.string.backup_now), onClick = onBackup)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onEncrypt, Modifier.weight(1f).height(56.dp)) { Icon(Icons.Outlined.Lock, null); Text("  " + stringResource(R.string.files_encrypt)) }
                FilledTonalButton(onClick = onDecrypt, Modifier.weight(1f).height(56.dp)) { Icon(Icons.Outlined.LockOpen, null); Text("  " + stringResource(R.string.files_decrypt)) }
            }
            Text(stringResource(R.string.files_names_visible), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            SectionTitle(stringResource(R.string.files_public_key))
            Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(publicKey?.let { it.take(24) + "…" + it.takeLast(8) } ?: "…", fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(stringResource(R.string.files_public_key_body), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { publicKey?.let(onCopyPublic) }, enabled = publicKey != null) { Icon(Icons.Outlined.ContentCopy, null); Text("  " + stringResource(R.string.files_copy)) }
                        OutlinedButton(onClick = { publicKey?.let(onSharePublic) }, enabled = publicKey != null) { Icon(Icons.Outlined.Share, null); Text("  " + stringResource(R.string.files_share)) }
                    }
                }
            }
            SectionTitle(stringResource(R.string.files_keys))
            Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                Column(Modifier.padding(vertical = 4.dp)) {
                    keys.forEachIndexed { i, key ->
                        if (i > 0) HorizontalDivider(Modifier.padding(start = 72.dp), color = MaterialTheme.colorScheme.outlineVariant)
                        val type = stringResource(if (Age.isPostQuantum(key.ageIdentity.orEmpty())) R.string.files_key_pq else R.string.files_key_x25519)
                        ListItem(headlineContent = { Text(key.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            supportingContent = { Text(if (i == 0) stringResource(R.string.files_key_current, type) else type) },
                            leadingContent = { IconBadge(Icons.Outlined.Key) }, modifier = Modifier.clickable { onOpenKey(key) },
                            colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent))
                    }
                }
            }
            Text(stringResource(R.string.files_keys_body), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { creating = true }) { Text(stringResource(R.string.files_new_key)) }
                TextButton(onClick = { importing = true }) { Text(stringResource(R.string.files_import_key)) }
            }
        }
    }
    if (creating) {
        var understood by remember { mutableStateOf(false) }
        AlertDialog(onDismissRequest = { creating = false }, icon = { Icon(Icons.Outlined.Key, null) }, title = { Text(stringResource(R.string.files_create_title)) },
            text = { HardenWindow(); Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(if (current == null) R.string.files_create_body else R.string.files_create_another_body))
                CheckRow(understood, { understood = it }) { Text(stringResource(R.string.files_create_understand), style = MaterialTheme.typography.bodyMedium) }
            } },
            confirmButton = { TextButton(onClick = { creating = false; onCreateKey() }, enabled = understood) { Text(stringResource(R.string.files_create_action)) } },
            dismissButton = { TextButton(onClick = { creating = false }) { Text(stringResource(R.string.main_cancel)) } })
    }
    if (importing) {
        var text by remember { mutableStateOf("") }
        val valid = Age.isIdentity(text)
        AlertDialog(onDismissRequest = { importing = false }, icon = { Icon(Icons.Outlined.Key, null) }, title = { Text(stringResource(R.string.files_import_key)) },
            text = { HardenWindow(); Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.files_import_body))
                OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.files_import_label)) }, singleLine = true, shape = RoundedCornerShape(12.dp),
                    visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                    isError = text.isNotBlank() && !valid, supportingText = { if (text.isNotBlank() && !valid) Text(stringResource(R.string.files_import_invalid)) })
            } },
            confirmButton = { TextButton(onClick = { val value = text.trim(); text = ""; importing = false; onImportKey(value) }, enabled = valid) { Text(stringResource(R.string.files_import_action)) } },
            dismissButton = { TextButton(onClick = { importing = false }) { Text(stringResource(R.string.main_cancel)) } })
    }
}

/** Shown while a file is encrypted or decrypted. */
@Composable
fun FileProgressDialog(progress: FileProgress, onCancel: () -> Unit) {
    AlertDialog(onDismissRequest = {}, icon = { Icon(if (progress.decrypting) Icons.Outlined.LockOpen else Icons.Outlined.Lock, null) },
        title = { Text(stringResource(if (progress.decrypting) R.string.files_decrypting else R.string.files_encrypting)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            val total = progress.total
            if (total != null && total > 0) LinearProgressIndicator(progress = { (progress.done.toFloat() / total).coerceIn(0f, 1f) }, Modifier.fillMaxWidth()) else LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(android.text.format.Formatter.formatShortFileSize(androidx.compose.ui.platform.LocalContext.current, progress.done), style = MaterialTheme.typography.bodySmall)
        } },
        confirmButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.main_cancel)) } })
}
