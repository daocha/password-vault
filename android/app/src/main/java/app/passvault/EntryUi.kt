package app.passvault

import androidx.annotation.StringRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

val FieldKind.icon: ImageVector get() = when (this) {
    FieldKind.username -> Icons.Outlined.Person
    FieldKind.password -> Icons.Outlined.Password
    FieldKind.note -> Icons.AutoMirrored.Outlined.Notes
    FieldKind.question -> Icons.Outlined.QuestionAnswer
}
val FieldKind.defaultLabel: String get() = when (this) {
    FieldKind.username -> "Username"
    FieldKind.password -> "Password"
    FieldKind.note -> "Notes"
    FieldKind.question -> "Security question"
}
/** Localized display names; [defaultLabel] stays English because it can be stored as a field label. */
@get:StringRes val FieldKind.defaultLabelRes: Int get() = when (this) {
    FieldKind.username -> R.string.seed_field_username
    FieldKind.password -> R.string.seed_field_password
    FieldKind.note -> R.string.seed_notes
    FieldKind.question -> R.string.seed_field_question
}

/** Stored labels that are really built-in names (created by the app or the importers); shown translated, never rewritten in the data. */
private val builtInLabels = mapOf(
    "Username" to R.string.app_label_username, "Password" to R.string.app_label_password, "Notes" to R.string.app_label_notes, "Security question" to R.string.app_label_question,
    SEED_LABEL to R.string.app_label_seed, SEED_PASSPHRASE_LABEL to R.string.app_label_passphrase, PRIVATE_KEY_LABEL to R.string.app_label_private_key,
    "Title" to R.string.app_label_title, "Website" to R.string.app_label_website, "Custom" to R.string.app_label_custom, "List" to R.string.app_label_list, "List item" to R.string.app_label_list_item,
    "Imported custom fields (original)" to R.string.app_label_imported_custom,
)
/** Display-only: a label the user typed themselves is returned unchanged. */
@Composable fun displayLabel(stored: String): String = builtInLabels[stored]?.let { stringResource(it) } ?: stored
val VaultField.displayName: String @Composable get() = displayLabel(label)

/** Tinted circular badge used for field kinds and section rows. */
@Composable
fun IconBadge(icon: ImageVector, size: Dp = 40.dp, container: Color = MaterialTheme.colorScheme.secondaryContainer, content: Color = MaterialTheme.colorScheme.onSecondaryContainer) {
    Box(Modifier.size(size).clip(CircleShape).background(container), contentAlignment = Alignment.Center) {
        Icon(icon, null, Modifier.size(size * 0.5f), tint = content)
    }
}

/** The brand's icon when the record is a well-known site or app, otherwise a letter avatar with a stable per-name color. */
@Composable
fun RecordAvatar(record: VaultRecord, size: Dp = 44.dp) {
    val brand = remember(record.website, record.name) { if (record.type != RecordType.seed) findBrand(record.website, record.name) else null }
    if (brand != null) Image(painterResource(brand.drawable), brand.title, Modifier.size(size).clip(RoundedCornerShape(size * 0.23f)))
    else RecordAvatar(record.name, size)
}

/** Letter avatar with a stable per-name color. */
@Composable
fun RecordAvatar(name: String, size: Dp = 44.dp) {
    val scheme = MaterialTheme.colorScheme
    val palette = listOf(scheme.primaryContainer to scheme.onPrimaryContainer, scheme.secondaryContainer to scheme.onSecondaryContainer, scheme.tertiaryContainer to scheme.onTertiaryContainer)
    val (container, content) = palette[Math.floorMod(name.lowercase().hashCode(), palette.size)]
    val letter = name.trim().firstOrNull { it.isLetterOrDigit() }?.uppercaseChar()?.toString() ?: "•"
    Box(Modifier.size(size).clip(CircleShape).background(container), contentAlignment = Alignment.Center) {
        Text(letter, color = content, style = if (size >= 56.dp) MaterialTheme.typography.headlineSmall else MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
    }
}

/** Checkbox whose whole row, label included, toggles it. */
@Composable
fun CheckRow(checked: Boolean, change: (Boolean) -> Unit, label: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.small).toggleable(checked, role = Role.Checkbox, onValueChange = change).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, null); Spacer(Modifier.width(8.dp)); label()
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier.padding(start = 4.dp, top = 8.dp, bottom = 8.dp), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

fun formatEpoch(seconds: Long): String? = runCatching { formatUpdated(Instant.ofEpochSecond(seconds).toString()) }.getOrNull()
fun formatUpdated(value: String): String? = runCatching {
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(ZoneId.systemDefault()).format(Instant.parse(value))
}.getOrNull()

@Composable
fun GeneratorOptionsEditor(options: GeneratorOptions, change: (GeneratorOptions) -> Unit) {
    Column {
        Text(stringResource(R.string.seed_gen_length, options.length), style = MaterialTheme.typography.labelLarge)
        Slider(options.length.toFloat(), { change(options.copy(length = it.toInt())) }, valueRange = GeneratorOptions.MIN_LENGTH.toFloat()..GeneratorOptions.MAX_LENGTH.toFloat(), steps = GeneratorOptions.MAX_LENGTH - GeneratorOptions.MIN_LENGTH - 1)
        // The last enabled character type cannot be switched off.
        @Composable fun Toggle(@StringRes label: Int, on: Boolean, letters: Boolean = false, set: (Boolean) -> GeneratorOptions) =
            Row(verticalAlignment = Alignment.CenterVertically) { Text(stringResource(label), Modifier.weight(1f)); Switch(on, { change(set(it)) }, enabled = !on || options.sets.size > (if (letters) 2 else 1)) }
        Toggle(R.string.seed_gen_letters, options.letters, letters = true) { options.copy(letters = it) }
        Toggle(R.string.seed_gen_numbers, options.numbers) { options.copy(numbers = it) }
        Toggle(R.string.seed_gen_symbols, options.symbols) { options.copy(symbols = it) }
    }
}

@Composable
fun GeneratorDialog(defaults: GeneratorOptions, onDismiss: () -> Unit, onUse: (String) -> Unit) {
    var options by remember { mutableStateOf(defaults) }
    var candidate by remember { mutableStateOf(PasswordGenerator.generate(defaults)) }
    AlertDialog(onDismissRequest = onDismiss, icon = { Icon(Icons.Outlined.Password, null) }, title = { Text(stringResource(R.string.seed_gen_title)) },
        text = {
            HardenWindow()
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerHighest) {
                    Row(Modifier.padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(candidate, Modifier.weight(1f).padding(vertical = 8.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyLarge)
                        IconButton(onClick = { candidate = PasswordGenerator.generate(options) }) { Icon(Icons.Outlined.Refresh, stringResource(R.string.seed_gen_another)) }
                    }
                }
                GeneratorOptionsEditor(options) { options = it; candidate = PasswordGenerator.generate(it) }
            }
        },
        confirmButton = { TextButton(onClick = { onUse(candidate) }) { Text(stringResource(R.string.seed_gen_use)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.seed_cancel)) } })
}
