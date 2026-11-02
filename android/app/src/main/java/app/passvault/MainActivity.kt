package app.passvault

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.SystemClock
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.view.WindowManager
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.StickyNote2
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.flow.first
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant

private enum class Export { encrypted, csv }
private sealed interface SettingsDialog {
    data object AutoLockChoice : SettingsDialog
    data object LanguageChoice : SettingsDialog
    data object ClipboardChoice : SettingsDialog
    data object Generator : SettingsDialog
    data object EnableBiometrics : SettingsDialog
    data object ChangePassword : SettingsDialog
    data object BackupReminderChoice : SettingsDialog
    data object DecoySetup : SettingsDialog
    data object TransferSend : SettingsDialog
    data object DecoyRemove : SettingsDialog
    data object DecoyManage : SettingsDialog
    data object DecoyReset : SettingsDialog
    data object AutofillHelp : SettingsDialog
    data class Exporting(val kind: Export) : SettingsDialog
}

/**
 * A transfer being sent: kept through a lock for [MainActivity.TRANSFER_KEEP_MILLIS] (leaving the app to share the file locks it), and
 * shown again only after unlocking the same vault it was made from.
 */
private class PendingTransfer(val code: String, val bytes: ByteArray, val source: FileVault, val expiresAt: Long) {
    /** Built once: the receiver starts over whenever the session id changes, so the frames must survive the screen coming back. */
    val frames: TransferFrames.Sender? = runCatching { TransferFrames.Sender(bytes) }.getOrNull()
}
private class ScannedImport(val records: List<VaultRecord>, val hotp: Int, val duplicates: Int)
/** Like [ActivityResultContracts.CreateDocument], with the MIME type chosen per file (name to type). */
private class CreateTypedDocument : androidx.activity.result.contract.ActivityResultContract<Pair<String, String>, android.net.Uri?>() {
    override fun createIntent(context: Context, input: Pair<String, String>) =
        Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(input.second).putExtra(Intent.EXTRA_TITLE, input.first)
    override fun parseResult(resultCode: Int, intent: Intent?) = intent?.data?.takeIf { resultCode == android.app.Activity.RESULT_OK }
}

/** Not a string resource: marks a password whose strength is still being estimated. */
private const val PASSWORD_CHECKING = 0
private val LANGUAGES = listOf("", "en", "zh-Hans", "zh-Hant")
private fun languageName(tag: String) = when (tag) { "en" -> R.string.main_language_english; "zh-Hans" -> R.string.main_language_zh_hans; "zh-Hant" -> R.string.main_language_zh_hant; else -> R.string.main_language_system }

class MainActivity : FragmentActivity() {
    private companion object { const val PICKER_GRACE_MILLIS = 120_000L; const val TRANSFER_KEEP_MILLIS = 10 * 60_000L }
    private lateinit var engine: VaultEngine
    private var ready by mutableStateOf(false)
    private var records by mutableStateOf(emptyList<VaultRecord>())
    private var unlocked by mutableStateOf(false)
    private var exists by mutableStateOf(true)
    private var busy by mutableStateOf(false)
    private var message by mutableStateOf("")
    private var messageError by mutableStateOf(false)
    private var selected by mutableStateOf(emptySet<String>())
    private var remaining by mutableIntStateOf(10)
    private var erased by mutableStateOf(false)
    private var backgroundLock: Job? = null
    private var backgroundSince = 0L
    private var lockTimeout: Long? = null
    private var systemPickerOpen = false
    private var autoLock by mutableStateOf(AutoLock.immediately)
    private var themeMode by mutableStateOf(ThemeMode.system)
    private var allowCopy by mutableStateOf(true)
    private var clipboardClear by mutableStateOf(ClipboardClear.m1)
    private var clearClipOnLock by mutableStateOf(true)
    private var generatorOptions by mutableStateOf(GeneratorOptions())
    private var clipToken: String? = null
    private val prefs by lazy { getSharedPreferences("settings", MODE_PRIVATE) }
    private var language by mutableStateOf("")
    /** Applies the in-app language override ("" follows the system) before any resources are read. */
    override fun attachBaseContext(newBase: Context) = super.attachBaseContext(withAppLanguage(newBase))
    private var biometricEnabled by mutableStateOf(false)
    /** Whether PassVault is the device's autofill service; read again whenever the app comes back. */
    private var autofillEnabled by mutableStateOf(false)
    private val autofillManager by lazy { getSystemService(android.view.autofill.AutofillManager::class.java) }
    private val autofillSetup = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { systemPickerOpen = false; autofillEnabled = autofillManager?.hasEnabledAutofillServices() == true }
    private var biometricAutoPrompted = false
    private var enablingBiometric = false
    private var importPreview by mutableStateOf<List<VaultRecord>?>(null)
    private val screenOff = object : BroadcastReceiver() { override fun onReceive(context: Context, intent: Intent) { if (unlocked) lockVault() else { discardPendingUnlock(); discardTransfer() } } }
    /** An unlock still deriving its key when the app leaves the foreground must not complete unattended: its result is dropped and the engine re-locked. */
    private fun discardPendingUnlock() { if (busy && !unlocked) generation++ }
    private var generation by mutableIntStateOf(0)
    private var settings by mutableStateOf(false)
    /** The vault health report; entries opened from it come back to it. */
    private var health by mutableStateOf(false)
    /** The report's open groups and scroll position, kept while an entry opened from it is shown; [healthFocus] is a group to scroll to. */
    private var healthOpen by mutableStateOf(emptySet<String>())
    private var healthList by mutableStateOf(androidx.compose.foundation.lazy.LazyListState())
    private var healthFocus by mutableStateOf<HealthSection?>(null)
    /** Opens the report with every group collapsed, or only [focus] open and scrolled to (e.g. from the expiry banner). */
    private fun openHealth(focus: HealthSection? = null) {
        healthOpen = setOfNotNull(focus?.name); healthList = androidx.compose.foundation.lazy.LazyListState(); healthFocus = focus; health = true
    }
    /** The open settings dialog; kept here so the backup reminder can open the export dialog directly. */
    private var settingsDialog by mutableStateOf<SettingsDialog?>(null)
    /** Phone-to-phone transfer: the one-time code and sealed payload being shown, or the scanner collecting one. */
    private var sending by mutableStateOf<PendingTransfer?>(null)
    private fun discardTransfer() { sending?.bytes?.fill(0); sending = null }
    private var receiving by mutableStateOf(false)
    private val transferFile = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        systemPickerOpen = false
        if (uri == null) return@registerForActivityResult
        // A copy: turning the screen off mid-write zeroes the pending transfer's own bytes.
        val transfer = sending ?: run { discardUnwritten(uri); return@registerForActivityResult }
        val bytes = transfer.bytes.copyOf(); val epoch = generation
        lifecycleScope.launch {
            // A transfer file is not a backup: its code is shown once and not kept, so it does not count toward the backup reminder.
            try { writeWholeFile(uri, bytes, transfer.source, plaintext = false); if (epoch == generation && unlocked) message = getString(R.string.transfer_saved) }
            catch (e: kotlinx.coroutines.CancellationException) { discardUnwritten(uri); throw e }
            catch (_: FileCrypt.LeftBehind) { /* Queued by the worker, even if the activity has gone. */ }
            catch (e: Exception) { if (epoch == generation && unlocked) { messageError = true; message = exportError(e) } }
            finally { bytes.fill(0) }
        }
    }
    /** The decoy vault is open: settings that would reveal or touch the real vault are not shown. */
    private var decoySession by mutableStateOf(false)
    private var decoyEnabled by mutableStateOf(false)
    /** Read at unlock, not when the dialog opens: the engine may be busy deriving a key and would block the main thread. */
    private var decoyResettable by mutableStateOf(false)
    // Each vault keeps its own backup history, so the decoy shows only its own.
    private val backups get() = BackupStatus(prefs, if (decoySession) "decoy." else "")
    private var lastBackup by mutableStateOf<Instant?>(null)
    private var backupSnapshotAt by mutableStateOf<Instant?>(null)
    private var backupInterval by mutableStateOf(BackupInterval.month)
    private var backupSnoozedUntil by mutableStateOf<Instant?>(null)
    private fun loadBackupStatus() { val b = backups; lastBackup = b.lastBackup; backupSnapshotAt = b.snapshotAt; backupInterval = b.interval; backupSnoozedUntil = b.snoozedUntil; backedUpKeys = b.fileKeys }
    private var backedUpKeys by mutableStateOf<Set<String>?>(null)
    private var tab by mutableStateOf(RecordType.login)
    /** Accounts read from a Google Authenticator export QR, waiting for the user to confirm adding them. */
    private var scannedImport by mutableStateOf<ScannedImport?>(null)
    // List filters live here, not in VaultScreen, so they survive opening an entry and coming back.
    private var query by mutableStateOf("")
    private var favorites by mutableStateOf(false)
    private var group by mutableStateOf<String?>(null)
    /** Cards or secure notes only, within the passwords tab; null shows every type. */
    private var kind by mutableStateOf<RecordType?>(null)
    private var viewing by mutableStateOf<VaultRecord?>(null)
    private var editing by mutableStateOf(false)
    private var importBytes by mutableStateOf<ByteArray?>(null)
    /** A KeePass key file chosen in the import password dialog. */
    private var importKeyFile by mutableStateOf<ByteArray?>(null)
    private val keyFilePicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        systemPickerOpen = false
        if (uri != null && unlocked) lifecycleScope.launch {
            val epoch = generation
            val bytes = runCatching { withContext(Dispatchers.IO) { contentResolver.openInputStream(uri)?.use { input ->
                val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (out.size() <= 1024 * 1024) { val n = input.read(buffer); if (n < 0) break; out.write(buffer, 0, n) }
                out.toByteArray()
            } } }.getOrNull()
            if (epoch != generation || !unlocked) { bytes?.fill(0); return@launch }
            if (bytes == null || bytes.size > 1024 * 1024) { bytes?.fill(0); messageError = true; message = getString(R.string.main_cannot_open_file); return@launch }
            importKeyFile?.fill(0); importKeyFile = bytes
        }
    }
    /** Owned here only until the save picker returns; a running write owns its own snapshot. */
    private var pendingExport: VaultExport? = null
    private fun discardPendingExport() { pendingExport?.clear(); pendingExport = null }
    private lateinit var biometricPrompt: BiometricPrompt
    // System back walks up one screen (editor → entry → list, settings → list); on the list it leaves the app.
    private val backCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            val record = viewing
            when {
                selected.isNotEmpty() -> selected = emptySet()
                sending != null -> discardTransfer()
                receiving -> receiving = false
                record != null && editing && records.any { it.id == record.id } -> editing = false
                record != null -> { viewing = null; editing = false }
                fileCrypt -> fileCrypt = false
                health -> health = false
                settings -> settings = false
            }
        }
    }
    private var biometricCandidate: ByteArray? = null
    private var biometricEpoch: Int? = null
    private val playUpdateLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        updates?.onPlayResult(result.resultCode)
    }
    /** Null in QA builds and in debug builds without a LAN update server: they never check for, download or offer updates. */
    internal val updates: AppUpdates? by lazy {
        if (BuildConfig.UPDATE_CHANNEL == "none") null else AppUpdates(this, playUpdateLauncher)
    }

    private val importPicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        systemPickerOpen = false
        if (uri != null && unlocked) lifecycleScope.launch {
            val epoch = generation
            try {
                val bytes = withContext(Dispatchers.IO) {
                    contentResolver.openInputStream(uri)?.use { input ->
                        val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                        while (true) { val count = input.read(buffer); if (count < 0) break; require(out.size() + count <= Records.MAX_BYTES + 64) { getString(R.string.main_file_too_large) }; out.write(buffer, 0, count) }
                        out.toByteArray()
                    } ?: error(getString(R.string.main_cannot_open_file))
                }
                if (epoch != generation || !unlocked) { bytes.fill(0); return@launch } // Locked while the file was read.
                importBytes?.fill(0); importBytes = null
                if (BackupFormat.isNewer(bytes)) { bytes.fill(0); throw NewerVersionException(backup = true) } // Not a CSV: say so before asking for a password.
                if (Importers.needsPassword(bytes)) importBytes = bytes // Password dialog decrypts it.
                else readImport({ try { Importers.importPlain(bytes) } finally { bytes.fill(0) } })
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) { if (epoch == generation && unlocked) { messageError = true; message = errorText(e, R.string.main_import_failed) } }
        }
    }
    /** Text for a failure: "update the app" for data from a newer version, otherwise the error's own message. */
    private fun errorText(e: Exception, fallback: Int): String =
        if (e is NewerVersionException) getString(if (e.backup) R.string.main_newer_backup else R.string.main_newer_vault) else e.message ?: getString(fallback)
    private fun readImport(parse: () -> List<VaultRecord>, parsed: () -> Unit = {}) {
        if (busy) return
        busy = true; message = ""; messageError = false; val epoch = generation
        lifecycleScope.launch {
            try { val result = withContext(Dispatchers.IO) { parse() }; parsed(); if (epoch == generation && unlocked) { if (result.isEmpty()) message = getString(R.string.main_file_no_records) else importPreview = result } }
            catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: AuthenticationFailure) { if (epoch == generation && unlocked) { messageError = true; message = getString(R.string.main_bad_password_or_backup) } }
            catch (e: Exception) { if (epoch == generation && unlocked) { messageError = true; message = errorText(e, R.string.main_import_rejected) } }
            finally { busy = false }
        }
    }
    private var cameraGranted: (() -> Unit)? = null
    private val cameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        systemPickerOpen = false
        val then = cameraGranted; cameraGranted = null
        if (granted && unlocked) then?.invoke() else if (!granted) { messageError = true; message = getString(R.string.totp_camera_denied) }
    }
    /** Runs [then] once the camera may be used, asking for the permission first if needed. */
    private fun withCamera(then: () -> Unit) {
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED) { then(); return }
        cameraGranted = then; systemPickerOpen = true; cameraPermission.launch(android.Manifest.permission.CAMERA)
    }
    private var imageRead: ((String?) -> Unit)? = null
    private val imagePicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        systemPickerOpen = false
        val then = imageRead; imageRead = null
        if (uri == null || then == null || !unlocked) return@registerForActivityResult
        val epoch = generation
        lifecycleScope.launch {
            val text = runCatching { withContext(Dispatchers.IO) { QrDecoder.decode(this@MainActivity, uri) } }.getOrNull()
            if (epoch == generation && unlocked) then(text)
        }
    }
    /** Shows the confirmation for a Google Authenticator export, leaving out accounts whose key is already in the vault. */
    private fun offerMigration(migration: Totp.Migration) {
        val known = records.mapNotNull { it.totp?.secret }
        val fresh = migration.accounts.filter { a -> known.none { it.contentEquals(a.secret) } }.distinctBy { it.secretBase32 }
        scannedImport = ScannedImport(fresh.map { it.record() }, migration.skipped, migration.accounts.size - fresh.size)
    }
    /** Settings › File encryption is open. */
    private var fileCrypt by mutableStateOf(false)
    private var fileProgress by mutableStateOf<FileProgress?>(null)
    private val fileJobs = FileJobs.shared
    private var fileJob: FileJobs.Ticket? = null
    private val fileNotices = FileNotices.shared
    private val fileRecovery by lazy { FileRecovery(applicationContext) }
    private var recoveryUnavailable by mutableStateOf(false)
    private fun fileVault(decoy: Boolean = decoySession) = FileVault(decoy, BackupStatus(prefs, if (decoy) "decoy." else "").instance)
    private fun clearVaultHistory(decoy: Boolean) {
        BackupStatus(prefs, if (decoy) "decoy." else "").clear()
        fileNotices.forgetBefore(fileVault(decoy))
    }
    /** The file chosen to encrypt or decrypt, waiting for the user to pick where the result goes. */
    private var fileSource: FileCrypt.Picked? = null
    /**
     * A pick, check and save flow is under way, from tapping Encrypt or Decrypt until the save picker returns (or the flow stops): only one
     * at a time, since the flow keeps its source in [fileSource]. Encrypt and Decrypt are disabled meanwhile, as during a job.
     */
    private var fileFlow by mutableStateOf(false)
    private fun startFileFlow(launch: () -> Unit) {
        if (fileFlow || fileJobs.running.value) return
        fileFlow = true
        if (!launchPicker(launch)) fileFlow = false
    }
    /** A file just encrypted whose plaintext original the user may delete. */
    private var encryptedOriginal by mutableStateOf<Pair<FileCrypt.Picked, String>?>(null)
    // No activity-level cache of private keys: a lazy derived state can retain its last value indefinitely after a lock.
    private val fileKeys: List<VaultRecord> get() = FileKeys.of(records)
    private val encryptSource = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        systemPickerOpen = false
        if (uri == null || !unlocked) { fileFlow = false; return@registerForActivityResult }
        val epoch = generation
        lifecycleScope.launch {
            var next = false
            try {
                val picked = withContext(Dispatchers.IO) { FileCrypt.describe(contentResolver, uri) }
                if (epoch != generation || !unlocked) return@launch
                fileSource = picked
                next = launchPicker { encryptTarget.launch(FileKeys.encryptedName(picked.name)) }
                if (!next) fileSource = null
            } finally { if (!next && epoch == generation) fileFlow = false }
        }
    }
    private val encryptTarget = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        systemPickerOpen = false; fileFlow = false
        val source = fileSource; fileSource = null
        val identity = fileKeys.firstOrNull()?.ageIdentity
        if (uri == null) return@registerForActivityResult
        if (source == null || identity == null || !unlocked) { discardUnwritten(uri); return@registerForActivityResult }
        if (FileCrypt.sameDocument(source.uri, uri)) { messageError = true; message = getString(R.string.files_same_file); return@registerForActivityResult }
        // The provider may have renamed the file (a name already taken); ask for its name on the worker, not the main thread.
        var savedAs: String? = null
        runFileJob(false, source.size, uri, { cancelled, progress, opened ->
            FileCrypt.encrypt(contentResolver, source.uri, uri, Age.parseIdentity(identity).recipient, cancelled, opened, progress); savedAs = FileCrypt.describe(contentResolver, uri).name
        }) { encryptedOriginal = source to (savedAs ?: FileKeys.encryptedName(source.name)) }
    }
    private val decryptSource = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        systemPickerOpen = false
        if (uri == null || !unlocked) { fileFlow = false; return@registerForActivityResult }
        val keys = fileKeys.mapNotNull { it.ageIdentity }; val epoch = generation
        lifecycleScope.launch {
            var next = false
            try { next = checkAndPickDecryptTarget(uri, keys, epoch) } finally { if (!next && epoch == generation) fileFlow = false }
        }
    }
    /** Checks [uri] can be decrypted with [keys], then opens the save picker; true when the picker opened. */
    private suspend fun checkAndPickDecryptTarget(uri: android.net.Uri, keys: List<String>, epoch: Int): Boolean {
        // Say "not your key" before asking where to save.
        val picked = try { withContext(Dispatchers.IO) { FileCrypt.check(contentResolver, uri, keys.map(Age::parseIdentity)); FileCrypt.describe(contentResolver, uri) } }
        catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: AgeException) { if (epoch == generation && unlocked) { messageError = true; message = ageError(e) }; return false }
        catch (e: Exception) { if (epoch == generation && unlocked) { messageError = true; message = getString(R.string.main_cannot_open_file) }; return false }
        if (epoch != generation || !unlocked) return false
        fileSource = picked
        val name = FileKeys.decryptedName(picked.name)
        val type = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
        if (!launchPicker { decryptTarget.launch(name to type) }) { fileSource = null; return false }
        return true
    }
    private val decryptTarget = registerForActivityResult(CreateTypedDocument()) { uri ->
        systemPickerOpen = false; fileFlow = false
        val source = fileSource; fileSource = null
        val keys = fileKeys.mapNotNull { it.ageIdentity }
        if (uri == null) return@registerForActivityResult
        if (source == null || !unlocked) { discardUnwritten(uri); return@registerForActivityResult }
        if (FileCrypt.sameDocument(source.uri, uri)) { messageError = true; message = getString(R.string.files_same_file); return@registerForActivityResult }
        runFileJob(true, source.size, uri, { cancelled, progress, opened -> FileCrypt.decrypt(contentResolver, source.uri, uri, keys.map(Age::parseIdentity), cancelled, opened, progress) }) { message = getString(R.string.files_decrypted) }
    }
    private val shareLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { systemPickerOpen = false }
    /**
     * Runs a file job off the main thread with a progress dialog, writing [output]. Cancelling, locking the vault or destroying the
     * activity stops it, and its output is then deleted. The job deletes its output when it stops itself; a stop that lands after the
     * job finished (including the coroutine being cancelled on its way back to the main thread) is caught here. Success counts only
     * once it is accepted on the main thread, where locking also runs, so nothing can lock between the last check and [done].
     */
    private fun runFileJob(decrypting: Boolean, total: Long?, output: android.net.Uri, job: (cancelled: () -> Boolean, progress: (Long) -> Unit, opened: () -> Unit) -> Unit, done: () -> Unit) {
        val ticket = fileJobs.start() ?: run { discardUnwritten(output); messageError = true; message = getString(R.string.files_busy); return }
        val epoch = generation; val sourceVault = fileVault(); fileJob = ticket; fileProgress = FileProgress(decrypting, 0, total)
        // Whether to tell the user: only in the session that ran the job (not on the unlock screen, nor in the other vault).
        fun here() = epoch == generation && unlocked
        val cancelled = { ticket.cancelled || epoch != generation }
        var shown = 0L
        var recoveryId: String? = null
        // Progress is reported on the worker; UI state changes on the main thread, and never after this job ended.
        lifecycleScope.launch {
            try {
                FileCrypt.guarded(Dispatchers.IO, cancelled, {
                    FileCrypt.discard(contentResolver, output).also {
                        if (it) fileRecovery.finish(recoveryId) else queueLeftBehind(sourceVault, output, decrypting, recoveryId)
                    }
                }, {
                    try { job(cancelled, { n -> if (n - shown >= 256 * 1024) { shown = n; runOnUiThread { if (fileJob === ticket && !ticket.cancelled && here()) fileProgress = FileProgress(decrypting, n, total) } } }, {
                        recoveryId = fileRecovery.begin(output, sourceVault, decrypting)
                    }) }
                    catch (e: FileCrypt.LeftBehind) { queueLeftBehind(sourceVault, output, decrypting, recoveryId); throw e }
                    catch (e: Exception) { fileRecovery.finish(recoveryId); throw e }
                }, { if (fileJob === ticket) fileProgress = null })
                // The main-thread acceptance above is the completion point. Commit it durably before displaying success.
                withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) { completeFileOutput(recoveryId, output, sourceVault, decrypting) }
                if (here()) done()
            } catch (e: kotlinx.coroutines.CancellationException) { throw e } // Cleanup and any warning were handled on the worker.
            catch (e: FileCrypt.Cancelled) { if (here()) message = getString(R.string.files_cancelled) }
            catch (_: FileCrypt.LeftBehind) { /* Queued by the worker. */ }
            catch (e: FileCrypt.SameFile) { if (here()) { messageError = true; message = getString(R.string.files_same_file) } }
            catch (e: FileCrypt.UnsafeTarget) { if (here()) { messageError = true; message = getString(R.string.files_new_target) } }
            catch (e: AgeException) { if (here()) { messageError = true; message = ageError(e) } }
            catch (e: Exception) { if (here()) { messageError = true; message = getString(R.string.files_failed) } }
            finally { fileJobs.finish(ticket); if (fileJob === ticket) { fileJob = null; fileProgress = null } }
        }
    }
    /**
     * The save picker has already created [uri] (empty) when it returns. When no job will write it (the vault locked while the picker was
     * open, or another job is still running), remove it, so no empty file is left looking like an encrypted or decrypted one. An existing
     * file the user picked to replace still has its content, and is kept.
     */
    private fun discardUnwritten(uri: android.net.Uri) {
        lifecycleScope.launch(Dispatchers.IO + kotlinx.coroutines.NonCancellable) { fileJobs.withOutput { FileCrypt.discardUnwritten(contentResolver, uri) } }
    }
    /** Called on the worker before coroutine cancellation can discard a cleanup failure on its way back to the activity. */
    private fun queueLeftBehind(source: FileVault, uri: android.net.Uri, plaintext: Boolean, recoveryId: String? = null) {
        val name = FileCrypt.describe(contentResolver, uri).name ?: getString(R.string.files_unknown_name)
        fileNotices.add(source, getString(if (plaintext) R.string.files_left_behind_plain else R.string.files_left_behind, name), recoveryId)
    }
    private suspend fun writeWholeFile(uri: android.net.Uri, bytes: ByteArray, source: FileVault, plaintext: Boolean) = fileJobs.withOutput {
        withContext(Dispatchers.IO) {
            var recoveryId: String? = null
            try {
                FileCrypt.writeWhole(contentResolver, uri, bytes) { recoveryId = fileRecovery.begin(uri, source, plaintext) }
                completeFileOutput(recoveryId, uri, source, plaintext)
            } catch (e: FileCrypt.LeftBehind) { queueLeftBehind(source, uri, plaintext, recoveryId); throw e }
            catch (e: Exception) { fileRecovery.finish(recoveryId); throw e }
        }
    }
    /** Failure to durably accept must not leave a file looking successful while recovery still considers it unfinished. */
    private fun completeFileOutput(id: String?, uri: android.net.Uri, source: FileVault, plaintext: Boolean) {
        try { fileRecovery.finish(id) }
        catch (e: Exception) {
            if (!FileCrypt.discard(contentResolver, uri)) { queueLeftBehind(source, uri, plaintext, id); throw FileCrypt.LeftBehind(e) }
            runCatching { fileRecovery.finish(id) }
            throw e
        }
    }
    private fun acknowledgeFileNotice(notice: FileNotices.Notice) {
        if (notice.recoveryId == null) { fileNotices.acknowledge(notice); return }
        lifecycleScope.launch {
            try {
                fileJobs.withOutput { withContext(Dispatchers.IO) { fileRecovery.finish(notice.recoveryId) } }
                fileNotices.acknowledge(notice)
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (_: Exception) { recoveryUnavailable = true }
        }
    }
    private fun ageError(e: AgeException) = getString(when (e.kind) {
        AgeException.Kind.noMatch -> R.string.files_no_match
        AgeException.Kind.passphrase -> R.string.files_passphrase
        AgeException.Kind.header, AgeException.Kind.armor -> R.string.files_not_age
        AgeException.Kind.hmac, AgeException.Kind.payload -> R.string.files_damaged
    })
    private fun createFileKey() {
        lifecycleScope.launch {
            val epoch = generation
            val identity = withContext(Dispatchers.Default) { Age.generateIdentity().encoded }
            // Another change may still be saving: wait for it rather than have work() drop the key without a word.
            snapshotFlow { busy }.first { !it }
            // Locked meanwhile, perhaps reopened as the other vault: the key must not land there.
            if (epoch != generation || !unlocked) return@launch
            saveRecord(FileKeys.newKey(getString(R.string.files_key_name), identity, getString(R.string.files_key_note), fileKeys)) { message = getString(R.string.files_key_created) }
        }
    }
    private fun importFileKey(identity: String) {
        val epoch = generation
        lifecycleScope.launch {
            // Another change may still be saving: wait for it rather than have work() drop the key without a word.
            snapshotFlow { busy }.first { !it }
            if (epoch != generation || !unlocked) return@launch
            if (fileKeys.any { it.ageIdentity.equals(identity, ignoreCase = true) }) { message = getString(R.string.files_key_exists); return@launch }
            val first = fileKeys.isEmpty()
            saveRecord(FileKeys.imported(getString(R.string.files_key_imported_name), identity.uppercase(), getString(R.string.files_key_note), fileKeys)) {
                message = getString(if (first) R.string.files_key_added else R.string.files_key_added_for_opening)
            }
        }
    }
    /** A public key is not secret: copied without the sensitive flag or the clearing timer. */
    private fun copyPublicKey(key: String) {
        getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("age public key", key)); message = getString(R.string.main_copied)
    }
    private fun sharePublicKey(key: String) {
        launchPicker { shareLauncher.launch(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, key), getString(R.string.files_public_key))) }
    }
    private val encryptedExport = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { writeExport(it) }
    private val csvExport = registerForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { writeExport(it) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Allow screenshots only in the debug APK; keep release and emulator QA screens protected.
        if (BuildConfig.BUILD_TYPE != "debug") window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        // Keep autofill services and content capture (screen-context features) from reading or saving what is typed here.
        window.decorView.importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        window.decorView.importantForContentCapture = android.view.View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
        // Tapjacking: hide other apps' overlays while visible, and ignore touches while anything is drawn on top.
        if (android.os.Build.VERSION.SDK_INT >= 31) window.setHideOverlayWindows(true)
        window.decorView.filterTouchesWhenObscured = true
        language = prefs.getString("language", "").orEmpty()
        autoLock = runCatching { AutoLock.valueOf(prefs.getString("autoLock", null) ?: "") }.getOrDefault(AutoLock.immediately)
        themeMode = runCatching { ThemeMode.valueOf(prefs.getString("theme", null) ?: "") }.getOrDefault(ThemeMode.system)
        clipboardClear = runCatching { ClipboardClear.valueOf(prefs.getString("clipboardClear", null) ?: "") }.getOrDefault(ClipboardClear.m1)
        generatorOptions = GeneratorOptions(prefs.getInt("genLength", 10).coerceIn(GeneratorOptions.MIN_LENGTH, GeneratorOptions.MAX_LENGTH), prefs.getBoolean("genLetters", true), prefs.getBoolean("genNumbers", true), prefs.getBoolean("genSymbols", true)).let { if (it.sets.isEmpty()) GeneratorOptions() else it }
        allowCopy = prefs.getBoolean("allowCopy", true); clearClipOnLock = prefs.getBoolean("clearClipOnLock", true)
        loadBackupStatus()
        biometricPrompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val epoch = biometricEpoch; biometricEpoch = null
                if (epoch == null || epoch != generation || !lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) {
                    enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null; return
                }
                val enable = enablingBiometric; enablingBiometric = false
                val authenticated = result.cryptoObject?.cipher ?: run { biometricCandidate?.fill(0); biometricCandidate = null; message = getString(R.string.main_biometric_no_key); return }
                if (enable) {
                    val candidate = biometricCandidate ?: return
                    biometricCandidate = null
                    work({ engine.saveBiometric(authenticated, candidate); null }, cleanup = { candidate.fill(0) }) { biometricEnabled = true; message = getString(R.string.main_biometric_enabled) }
                } else work({ engine.unlockBiometric(authenticated) })
            }
            override fun onAuthenticationError(code: Int, error: CharSequence) {
                biometricEpoch = null; enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null
                if (code != BiometricPrompt.ERROR_USER_CANCELED && code != BiometricPrompt.ERROR_NEGATIVE_BUTTON && code != BiometricPrompt.ERROR_CANCELED) message = error.toString()
            }
        })
        onBackPressedDispatcher.addCallback(this, backCallback)
        lifecycleScope.launch { snapshotFlow { unlocked && (viewing != null || settings || fileCrypt || health || sending != null || receiving || selected.isNotEmpty()) }.collect { backCallback.isEnabled = it } }
        ContextCompat.registerReceiver(this, screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED)
        lifecycleScope.launch {
            try {
                fileJobs.withOutput { withContext(Dispatchers.IO) {
                    val pending = fileRecovery.recover()
                    fileNotices.retainRecovery(pending.map { it.id }.toSet())
                    pending.forEach { entry -> fileNotices.add(entry.source, getString(
                        if (entry.plaintext) R.string.files_left_behind_plain else R.string.files_left_behind,
                        entry.name.ifEmpty { getString(R.string.files_unknown_name) }), entry.id) }
                } }
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (_: Exception) { recoveryUnavailable = true }
        }
        // A storage provider can be slow or unavailable. Recovery owns file output, but must not block vault initialization/unlock.
        lifecycleScope.launch {
            try {
                val status = withContext(vaultQueue) {
                    engine = VaultEngine(ProtectedStorage(this@MainActivity))
                    Triple(engine.exists(), engine.remainingAttempts(), engine.hasBiometric())
                }
                exists = status.first; remaining = status.second; biometricEnabled = status.third; ready = true
                if (lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)) autoBiometrics()
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) {
                message = errorText(e, R.string.main_storage_unavailable)
                if (::engine.isInitialized) { erased = withContext(vaultQueue) { runCatching { engine.isErased() }.getOrDefault(false) }; ready = erased }
            }
        }
        setContent {
            val fileWorking by fileJobs.running.collectAsState()
            val notices by fileNotices.pending.collectAsState()
            PassVaultTheme(themeMode) { BlockTextCopy(!allowCopy, ::copySecret) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                        key(generation) {
                            val record = viewing
                            when {
                                !unlocked -> UnlockScreen()
                                sending != null -> sending?.let { t -> TransferSendScreen(t.frames, t.code, onSaveFile = { launchPicker { transferFile.launch("passvault_transfer_" + exportFileName("pvtransfer").removePrefix("passvault_")) } }, onDone = { discardTransfer() }) }
                                receiving -> TransferReceiveScreen(this@MainActivity, onComplete = { data -> receiving = false; importBytes?.fill(0); importBytes = data }, onCancel = { receiving = false })
                                record != null -> RecordScreen(record, editing)
                                health -> HealthScreen(records, healthOpen, onToggle = { key -> healthOpen = if (key in healthOpen) healthOpen - key else healthOpen + key }, healthList, healthFocus,
                                    onFocused = { healthFocus = null }, onBack = { health = false }, onOpen = { viewing = it; editing = false })
                                fileCrypt -> { val keys = fileKeys
                                    FileEncryptionScreen(keys, remember(keys, lastBackup, backedUpKeys) { FileKeys.needsBackup(keys, lastBackup, backedUpKeys) }, onBack = { fileCrypt = false }, onCreateKey = ::createFileKey, onImportKey = ::importFileKey,
                                        working = fileFlow || fileWorking,
                                        onEncrypt = { startFileFlow { encryptSource.launch(arrayOf("*/*")) } }, onDecrypt = { startFileFlow { decryptSource.launch(arrayOf("*/*")) } },
                                        onCopyPublic = ::copyPublicKey, onSharePublic = ::sharePublicKey, onOpenKey = { viewing = it; editing = false },
                                        onBackup = { fileCrypt = false; settings = true; settingsDialog = SettingsDialog.Exporting(Export.encrypted) }) }
                                settings -> SettingsScreen()
                                else -> VaultScreen()
                            }
                        }
                        if (unlocked) ImportDialogs()
                        if (unlocked) FileDialogs()
                        if (unlocked && recoveryUnavailable) AlertDialog(onDismissRequest = {}, icon = { Icon(Icons.Default.Warning, null) },
                            title = { Text(stringResource(R.string.files_attention_title)) },
                            text = { HardenWindow(); Text(stringResource(R.string.files_recovery_failed)) },
                            confirmButton = { TextButton(onClick = { recoveryUnavailable = false }) { Text(stringResource(R.string.main_ok)) } })
                        if (unlocked && !recoveryUnavailable) notices.firstOrNull { it.source == fileVault() }?.let { notice ->
                            AlertDialog(onDismissRequest = {}, icon = { Icon(Icons.Default.Warning, null) },
                                title = { Text(stringResource(R.string.files_attention_title)) },
                                text = { HardenWindow(); Text(notice.text) },
                                confirmButton = { TextButton(onClick = { acknowledgeFileNotice(notice) }) { Text(stringResource(R.string.main_ok)) } })
                        }
                        if (busy) Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background.copy(alpha = .92f)) { Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) { CircularProgressIndicator(); Spacer(Modifier.height(16.dp)); Text(stringResource(R.string.main_securing)) } }
                        if (message.isNotEmpty()) {
                            val shown = message
                            LaunchedEffect(shown) { delay(6000); if (message == shown) { message = ""; messageError = false } }
                            val error = messageError
                            Snackbar(Modifier.align(Alignment.TopCenter).padding(16.dp), containerColor = if (error) MaterialTheme.colorScheme.errorContainer else SnackbarDefaults.color, contentColor = if (error) MaterialTheme.colorScheme.onErrorContainer else SnackbarDefaults.contentColor,
                                dismissAction = { TextButton(onClick = { message = ""; messageError = false }) { Text(stringResource(R.string.main_ok), color = if (error) MaterialTheme.colorScheme.onErrorContainer else SnackbarDefaults.actionColor) } }) {
                                Row(verticalAlignment = Alignment.CenterVertically) { if (error) Icon(Icons.Default.Warning, null, Modifier.padding(end = 12.dp)); Text(shown) }
                            }
                        }
                    }
                }
            } }
        }
    }
    override fun onStart() {
        super.onStart()
        backgroundLock?.cancel(); backgroundLock = null
        if (!unlocked) return
        val timeout = lockTimeout
        if (getSystemService(KeyguardManager::class.java).isDeviceLocked || (timeout != null && backgroundSince > 0 && SystemClock.elapsedRealtime() - backgroundSince >= timeout)) lockVault()
    }
    override fun onResume() {
        super.onResume()
        updates?.onResume()
        autofillEnabled = autofillManager?.hasEnabledAutofillServices() == true
        autoBiometrics()
    }
    /** Also called when asynchronous startup completes after onResume. */
    private fun autoBiometrics() {
        if (ready && exists && !unlocked && !busy && !biometricAutoPrompted && biometricEnabled) { biometricAutoPrompted = true; biometrics() }
    }
    override fun onStop() {
        super.onStop()
        biometricEpoch = null; enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null
        if (::biometricPrompt.isInitialized) biometricPrompt.cancelAuthentication()
        backgroundSince = 0; lockTimeout = null
        if (isChangingConfigurations) return
        if (!unlocked) { discardPendingUnlock(); return }
        backgroundSince = SystemClock.elapsedRealtime()
        // The app's own system pickers get a bounded grace period instead of suspending auto-lock, so leaving from inside a picker still locks.
        val timeout = if (systemPickerOpen) PICKER_GRACE_MILLIS else autoLock.millis ?: return // deviceLock: the screen-off receiver locks.
        lockTimeout = timeout
        if (timeout == 0L) lockVault(clearClipboard = false, keepTransfer = true) else { backgroundLock?.cancel(); backgroundLock = lifecycleScope.launch { delay(timeout); lockVault(keepTransfer = true) } }
    }
    /** [keepTransfer]: the lock comes from leaving the app (perhaps to share the transfer file), not from turning the screen off. */
    private fun lockVault(clearClipboard: Boolean = true, keepTransfer: Boolean = false) {
        if (clearClipboard && clearClipOnLock && unlocked) clearCopiedText()
        clearVaultSession()
        // A transfer outlives the lock for a while, so its code is still there after sharing the file from another app.
        if (!keepTransfer || sending?.let { SystemClock.elapsedRealtime() >= it.expiresAt } != false) discardTransfer()
        if (::engine.isInitialized) lifecycleScope.launch(vaultQueue) { engine.lock() }
    }
    /** A worker may retain this activity after destruction; release its decrypted records and every transient secret at once. */
    private fun clearVaultSession() {
        generation++; unlocked = false; records = emptyList(); decoySession = false; decoyEnabled = false; decoyResettable = false; selected = emptySet(); query = ""; favorites = false; group = null; kind = null; viewing = null; editing = false; settings = false; health = false; settingsDialog = null; receiving = false;
        message = ""; messageError = false
        scannedImport = null; cameraGranted = null; imageRead = null
        // A running file job sees the new generation and stops; its half-written output is deleted.
        fileCrypt = false; fileSource = null; fileFlow = false; encryptedOriginal = null; fileJob?.cancel(); fileProgress = null
        backgroundLock?.cancel(); backgroundLock = null; biometricAutoPrompted = false
        importPreview = null; importBytes?.fill(0); importBytes = null; importKeyFile?.fill(0); importKeyFile = null; discardPendingExport()
        if (::biometricPrompt.isInitialized) biometricPrompt.cancelAuthentication()
        biometricEpoch = null; enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null
    }
    override fun onDestroy() {
        updates?.close()
        clearVaultSession()
        unregisterReceiver(screenOff); discardTransfer()
        // The auto-lock coroutine dies with this activity, so zero the data key now (off the main thread: the engine may be mid-Argon2).
        if (::engine.isInitialized) { val e = engine; Thread { e.lock() }.start() }
        super.onDestroy()
    }
    private fun work(action: () -> List<VaultRecord>?, cleanup: () -> Unit = {}, done: () -> Unit = {}) {
        if (!ready || busy) { cleanup(); return }
        busy = true; message = ""; messageError = false; val epoch = generation
        lifecycleScope.launch {
            try {
                var decoy = false; var hasDecoy = false; var canResetDecoy = false; var attemptsRemaining = 10
                val result = withContext(vaultQueue) { VaultAccess.serialized {
                    val result = action()
                    if (result != null) { decoy = engine.isDecoy(); hasDecoy = engine.hasDecoy(); canResetDecoy = engine.canResetDecoy() }
                    attemptsRemaining = engine.remainingAttempts()
                    result
                } }
                if (epoch != generation) {
                    withContext(vaultQueue) { engine.lock() }
                    // The action itself completed (e.g. a vault was created or reset), so refresh what the unlock screen shows.
                    refreshUnlockScreen()
                    return@launch
                }
                if (result != null) {
                    records = result; unlocked = true; exists = true
                    decoySession = decoy; decoyEnabled = hasDecoy; decoyResettable = canResetDecoy; loadBackupStatus()
                    // Only the vault that made a pending transfer may see it again.
                    sending?.let { if (it.source != fileVault() || SystemClock.elapsedRealtime() >= it.expiresAt) discardTransfer() }
                }
                remaining = attemptsRemaining; done()
            } catch (e: Exception) { reportWorkError(e) }
            finally { cleanup(); busy = false }
        }
    }
    /** Locking does not re-read the attempt count or erasure; a task that ran past a lock may have changed both. */
    private suspend fun refreshUnlockScreen() {
        val status = withContext(vaultQueue) { Triple(runCatching { engine.exists() }.getOrDefault(exists), runCatching { engine.isErased() }.getOrDefault(erased), runCatching { engine.remainingAttempts() }.getOrDefault(remaining)) }
        exists = status.first; erased = status.second; remaining = status.third
    }
    private suspend fun reportWorkError(e: Exception) {
        // A failure after the action opened the engine (in the status reads that follow an unlock, say) must not leave it open behind
        // the unlock screen: until the UI shows the vault, the engine stays locked.
        if (!unlocked) withContext(vaultQueue) { runCatching { engine.lock() } }
        if (!withContext(vaultQueue) { runCatching { engine.isUnlocked() }.getOrDefault(false) }) lockVault()
        val status = withContext(vaultQueue) { runCatching { engine.remainingAttempts() }.getOrDefault(0) to runCatching { engine.isErased() }.getOrDefault(false) }
        remaining = status.first; erased = status.second
        if (erased) biometricEnabled = false
        messageError = true
        message = if (e is AuthenticationFailure && !erased) getString(R.string.main_incorrect_password, remaining) else errorText(e, R.string.main_operation_failed)
    }
    private fun saveRecord(saved: VaultRecord, done: () -> Unit = {}) {
        val updated = if (records.any { it.id == saved.id }) records.map { if (it.id == saved.id) saved else it } else records + saved
        work({ engine.save(updated) }, done = done)
    }
    private fun biometrics(password: String? = null) {
        if (busy || !ready) return
        val enable = password != null
        if (BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) != BiometricManager.BIOMETRIC_SUCCESS) { message = getString(R.string.main_biometric_not_enrolled); return }
        if (!enable && !biometricEnabled) { message = getString(R.string.main_biometric_use_password_first); return }
        var candidate: ByteArray? = null
        var cipher: javax.crypto.Cipher? = null; var invalidated = false
        work({
            if (enable) candidate = engine.biometricKey(password!!)
            try { cipher = engine.biometricCipher(enable) }
            catch (_: KeyPermanentlyInvalidatedException) { engine.disableBiometric(); invalidated = true }
            null
        }, cleanup = { candidate?.fill(0) }) {
            if (invalidated) { biometricEnabled = false; message = getString(R.string.main_biometrics_changed); return@work }
            try {
                biometricCandidate = candidate; candidate = null
                enablingBiometric = enable
                biometricEpoch = generation
                biometricPrompt.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(if (enable) getString(R.string.main_enable_biometric_unlock) else getString(R.string.main_unlock_passvault)).setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG).setNegativeButtonText(getString(R.string.main_use_app_password)).build(), BiometricPrompt.CryptoObject(checkNotNull(cipher)))
            } catch (e: Exception) { biometricEpoch = null; enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null; message = e.message ?: getString(R.string.main_biometric_key_unavailable) }
        }
    }
    private fun disableBiometrics() {
        work({ engine.disableBiometric(); null }) { biometricEnabled = false; message = getString(R.string.main_biometric_turned_off) }
    }

    @Composable private fun UnlockScreen() {
        var password by remember { mutableStateOf("") }; var confirm by remember { mutableStateOf("") }; var consent by remember { mutableStateOf(false) }; var reset by remember { mutableStateOf(false) }
        // Only a new password is checked; the unlock password is never estimated.
        val problem = if (exists) null else passwordProblem(password)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Image(painterResource(R.drawable.vault_icon), stringResource(R.string.main_logo_description), Modifier.size(112.dp))
            Spacer(Modifier.height(24.dp)); WordMark(MaterialTheme.typography.headlineLarge)
            Text(stringResource(R.string.main_tagline), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (erased) { Text(stringResource(R.string.main_vault_erased), Modifier.padding(top = 16.dp)); TextButton(onClick = { reset = true }) { Text(stringResource(R.string.main_start_new_vault)) } }
            Spacer(Modifier.height(32.dp)); SecretInput(if (exists) stringResource(R.string.main_app_password) else stringResource(R.string.main_new_app_password), password, { password = it })
            if (!exists) {
                Spacer(Modifier.height(8.dp)); SecretInput(stringResource(R.string.main_repeat_password), confirm, { confirm = it })
                if (confirm.isNotEmpty() && !samePassword(password, confirm)) Text(stringResource(R.string.main_passwords_dont_match), Modifier.fillMaxWidth().padding(top = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                PasswordHint(password, problem)
                Text(stringResource(R.string.main_no_password_reset), Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                CheckRow(consent, { consent = it }) { Text(stringResource(R.string.main_consent_erase)) }
            }
            Button(onClick = { val value = password; password = ""; confirm = ""; work({ if (exists) engine.unlock(value) else engine.create(value) }) }, enabled = ready && password.isNotEmpty() && (exists || (samePassword(password, confirm) && consent && problem == null)), modifier = Modifier.fillMaxWidth().padding(top = 16.dp).height(52.dp)) { Text(if (exists) stringResource(R.string.main_unlock_vault) else stringResource(R.string.main_create_vault)) }
            if (exists && biometricEnabled) OutlinedButton(onClick = { biometrics() }, enabled = ready, modifier = Modifier.fillMaxWidth().padding(top = 8.dp).height(52.dp)) { Icon(Icons.Default.Fingerprint, null); Text("  " + stringResource(R.string.main_unlock_with_biometrics)) }
            if (exists) Text(stringResource(R.string.main_attempts_remaining, remaining), Modifier.padding(top = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (reset) AlertDialog(onDismissRequest = { reset = false }, title = { Text(stringResource(R.string.main_new_empty_vault_title)) }, text = { HardenWindow(); Text(stringResource(R.string.main_erased_cannot_recover)) }, confirmButton = { TextButton(onClick = { reset = false; work({ engine.resetErasedVault(); clearVaultHistory(false); clearVaultHistory(true); null }) { erased = false; exists = false; remaining = 10; message = getString(R.string.main_create_then_import) } }) { Text(stringResource(R.string.main_create_new_vault)) } }, dismissButton = { TextButton(onClick = { reset = false }) { Text(stringResource(R.string.main_cancel)) } })
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun VaultScreen() {
        var confirmDelete by remember { mutableStateOf(false) }; var grouping by remember { mutableStateOf(false) }; var creating by remember { mutableStateOf(false) }
        var reordering by remember { mutableStateOf(false) }
        val selecting = selected.isNotEmpty(); val haptics = LocalHapticFeedback.current
        // The search bar is opened from the top bar and tucks away once the user starts scrolling the results; the query stays applied.
        var searchOpen by remember { mutableStateOf(false) }; val searchFocus = remember { androidx.compose.ui.focus.FocusRequester() }
        val focusManager = androidx.compose.ui.platform.LocalFocusManager.current; val listState = rememberLazyListState()
        // The field keeps its own selection so reopening the bar puts the cursor after the text; [query] stays the source of truth.
        var field by remember { mutableStateOf(androidx.compose.ui.text.input.TextFieldValue(query)) }
        LaunchedEffect(query) { if (field.text != query) field = androidx.compose.ui.text.input.TextFieldValue(query, androidx.compose.ui.text.TextRange(query.length)) }
        LaunchedEffect(searchOpen) { if (searchOpen) { field = androidx.compose.ui.text.input.TextFieldValue(query, androidx.compose.ui.text.TextRange(query.length)); searchFocus.requestFocus() } }
        LaunchedEffect(listState) { snapshotFlow { listState.isScrollInProgress }.collect { if (it && searchOpen) { focusManager.clearFocus(); searchOpen = false } } }
        val type = tab; val seedTab = tab == RecordType.seed; val totpTab = tab == RecordType.totp
        val ofType = records.filter { it.type.tab == type }
        val groups = remember(records) { VaultFolders.names(records) }
        // A group filter whose last entry was moved or deleted has no chip left to clear it.
        LaunchedEffect(groups) { if (group != null && group !in groups) group = null }
        LaunchedEffect(ofType) { if (kind != null && ofType.none { it.type == kind }) kind = null }
        val visible = ofType.filter { it.matches(query) && (!favorites || it.favorite) && (group == null || it.group.trim() == group) && (kind == null || it.type == kind) }
            .sortedWith(if (totpTab) TotpOrder.comparator else compareBy({ !it.favorite }, { it.name.lowercase() }))
        // Bulk actions apply only to entries the user can see: narrowing the filters drops hidden entries from the selection.
        LaunchedEffect(visible) { val ids = visible.map { it.id }.toSet(); if (!ids.containsAll(selected)) selected = selected intersect ids }
        // Reordering always covers every code, whatever the search or favorites filter shows.
        if (reordering && totpTab) { TotpReorder(remember { ofType.sortedWith(TotpOrder.comparator) }, onCancel = { reordering = false }) { ids ->
            val updated = TotpOrder.apply(records, ids, Instant.now().toString()); work({ engine.save(updated); updated }) { reordering = false; message = getString(R.string.totp_reordered) }
        }; return }
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                if (selecting) TopAppBar(title = { Text(stringResource(R.string.main_selected_count, selected.size)) }, navigationIcon = { IconButton(onClick = { selected = emptySet() }) { Icon(Icons.Default.Close, stringResource(R.string.main_cancel_selection)) } },
                    actions = {
                        IconButton(onClick = { val ids = visible.map { it.id }.toSet(); selected = if (selected.containsAll(ids)) emptySet() else ids }) { Icon(Icons.Outlined.SelectAll, stringResource(R.string.main_select_all)) }
                        if (tab == RecordType.login) IconButton(onClick = { grouping = true }) { Icon(Icons.Outlined.Folder, stringResource(R.string.main_change_group_selected)) }
                        IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.Delete, stringResource(R.string.main_delete_selected)) }
                    }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.secondaryContainer))
                else TopAppBar(title = { WordMark(MaterialTheme.typography.titleLarge) }, actions = { IconButton(onClick = { searchOpen = !searchOpen }) { Icon(Icons.Default.Search, stringResource(R.string.main_search), tint = if (query.isNotEmpty()) MaterialTheme.colorScheme.primary else LocalContentColor.current) }; IconButton(onClick = { openHealth() }) { Icon(Icons.Outlined.HealthAndSafety, stringResource(R.string.health_title)) }; IconButton(onClick = { fileCrypt = true }) { Icon(EncryptedFileIcon, stringResource(R.string.files_title)) }; IconButton(onClick = { lockVault() }) { Icon(Icons.Outlined.Lock, stringResource(R.string.main_lock_vault)) }; Box { IconButton(onClick = { settings = true }) { Icon(Icons.Outlined.Settings, stringResource(R.string.main_settings)) }; if (updates?.ui?.hasUpdate == true) Box(Modifier.align(Alignment.TopEnd).padding(10.dp).size(8.dp).background(MaterialTheme.colorScheme.error, CircleShape)) } }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
            },
            floatingActionButton = { if (!selecting) Box {
                ExtendedFloatingActionButton(onClick = { if (tab == RecordType.login) creating = true else { viewing = VaultRecord(type = tab, fields = emptyList()); editing = true } }, icon = { Icon(if (totpTab) Icons.Outlined.QrCodeScanner else Icons.Default.Add, null) }, text = { Text(stringResource(when (tab) { RecordType.seed -> R.string.main_new_seed_phrase; RecordType.totp -> R.string.totp_add; else -> R.string.main_new_entry })) })
                // Logins, cards and secure notes share this tab, so the button asks which one.
                DropdownMenu(creating, { creating = false }) {
                    listOf(Triple(RecordType.login, Icons.Outlined.Key, R.string.rec_new_login), Triple(RecordType.card, Icons.Outlined.CreditCard, R.string.rec_new_card), Triple(RecordType.note, Icons.AutoMirrored.Outlined.StickyNote2, R.string.rec_new_note)).forEach { (t, icon, label) ->
                        DropdownMenuItem(text = { Text(stringResource(label)) }, leadingIcon = { Icon(icon, null) }, onClick = { creating = false; viewing = VaultRecord(type = t, fields = defaultFields(t)); editing = true })
                    }
                }
            } }) { padding ->
            Column(Modifier.padding(padding).padding(horizontal = 16.dp)) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(bottom = if (searchOpen) 12.dp else 0.dp)) {
                    listOf(Triple(RecordType.login, Icons.Outlined.Key, R.string.main_passwords), Triple(RecordType.seed, Icons.Outlined.AccountBalanceWallet, R.string.main_seed_phrases), Triple(RecordType.totp, Icons.Outlined.Pin, R.string.totp_tab)).forEachIndexed { i, (t, icon, label) ->
                        SegmentedButton(tab == t, { if (tab != t) query = ""; tab = t; group = null; kind = null; selected = emptySet() }, SegmentedButtonDefaults.itemShape(i, 3), icon = { Icon(icon, null, Modifier.size(18.dp)) }) { Text(stringResource(label), maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    }
                }
                if (searchOpen) TextField(field, { field = it; query = it.text }, Modifier.fillMaxWidth().focusRequester(searchFocus), placeholder = { Text(stringResource(R.string.main_search)) }, leadingIcon = { Icon(Icons.Default.Search, null) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Default.Close, stringResource(R.string.main_clear_search)) } }, singleLine = true, shape = RoundedCornerShape(28.dp),
                    colors = TextFieldDefaults.colors(focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh, focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh))
                LazyRow(Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item { FilterChip(favorites, { favorites = !favorites }, label = { Text(stringResource(R.string.main_favorites)) }, leadingIcon = { Icon(if (favorites) Icons.Default.Star else Icons.Outlined.StarOutline, null, Modifier.size(18.dp)) }) }
                    if (tab == RecordType.login) for ((t, icon, label) in listOf(Triple(RecordType.card, Icons.Outlined.CreditCard, R.string.rec_filter_cards), Triple(RecordType.note, Icons.AutoMirrored.Outlined.StickyNote2, R.string.rec_filter_notes))) if (ofType.any { it.type == t })
                        item { FilterChip(kind == t, { kind = if (kind == t) null else t }, label = { Text(stringResource(label)) }, leadingIcon = { Icon(icon, null, Modifier.size(18.dp)) }) }
                    if (tab == RecordType.login) items(groups) { name -> FilterChip(group == name, { group = if (group == name) null else name }, label = { Text(name) },
                        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Color(groupColorArgb(name)).copy(alpha = 0.28f), selectedLabelColor = MaterialTheme.colorScheme.onSurface),
                        border = FilterChipDefaults.filterChipBorder(true, group == name, borderColor = Color(groupColorArgb(name)), selectedBorderColor = Color(groupColorArgb(name)), borderWidth = 1.dp, selectedBorderWidth = 2.dp)) }
                }
                if (!selecting && remember(records, lastBackup, backupSnapshotAt, backupInterval, backupSnoozedUntil) { BackupReminder.due(records, lastBackup, backupInterval, backupSnoozedUntil, snapshotAt = backupSnapshotAt) }) {
                    val last = lastBackup
                    AttentionBanner(Icons.Outlined.SaveAlt, if (last == null) stringResource(R.string.backup_banner_never) else stringResource(R.string.backup_banner_due, backupAge(last), BackupReminder.changedSince(records, backupSnapshotAt)),
                        stringResource(R.string.backup_now), onDismiss = { backups.snooze(); loadBackupStatus() }) { settings = true; settingsDialog = SettingsDialog.Exporting(Export.encrypted) }
                }
                val expiring = remember(records) { records.count { it.needsNotice() } }
                if (expiring > 0 && !selecting) SlimNotice(Icons.Outlined.Event, stringResource(R.string.health_banner_expiring, expiring), stringResource(R.string.health_review)) { openHealth(HealthSection.expiring) }
                if (ofType.isEmpty()) Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    IconBadge(when (tab) { RecordType.seed -> Icons.Outlined.AccountBalanceWallet; RecordType.totp -> Icons.Outlined.Pin; else -> Icons.Outlined.Key }, 72.dp); Spacer(Modifier.height(16.dp))
                    Text(stringResource(when (tab) { RecordType.seed -> R.string.main_no_seed_phrases; RecordType.totp -> R.string.totp_empty_title; else -> R.string.main_peace_of_mind }), style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(when (tab) { RecordType.seed -> R.string.main_empty_seed_body; RecordType.totp -> R.string.totp_empty_body; else -> R.string.main_empty_login_body }), Modifier.padding(top = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                } else Row(Modifier.fillMaxWidth().padding(start = 4.dp, bottom = 8.dp).heightIn(min = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(when (tab) { RecordType.seed -> R.string.main_count_of_seeds; RecordType.totp -> R.string.totp_count; else -> R.string.main_count_of_entries }, visible.size, ofType.size), Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (totpTab && ofType.size > 1 && !selecting) TextButton(onClick = { searchOpen = false; reordering = true }, Modifier.height(32.dp).testTag(REORDER_BUTTON), contentPadding = PaddingValues(horizontal = 8.dp)) {
                        Icon(Icons.Default.SwapVert, null, Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.totp_reorder), style = MaterialTheme.typography.labelLarge)
                    }
                }
                // One clock for every visible code, so they all change together.
                val now = if (totpTab) rememberNowMillis() else 0L
                LazyColumn(state = listState, verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 96.dp)) {
                    items(visible, key = { it.id }) { record ->
                        val totp = if (record.type == RecordType.totp) remember(record) { record.totp } else null
                        val subtitle = when (record.type) {
                            RecordType.totp -> totp?.account.orEmpty()
                            RecordType.seed -> if (record.privateKey != null) stringResource(R.string.main_private_key) else stringResource(R.string.main_word_count, record.seedWords.size)
                            RecordType.card -> record.cardSummary
                            RecordType.note -> record.fields.firstOrNull { it.kind == FieldKind.note && it.value.isNotBlank() }?.value?.lineSequence()?.first().orEmpty()
                            RecordType.login -> record.fields.firstOrNull { it.kind == FieldKind.username && it.value.isNotBlank() }?.value ?: record.website
                        }
                        val isSelected = record.id in selected
                        fun toggle() { selected = if (isSelected) selected - record.id else selected + record.id }
                        Card(modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = if (isSelected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLow)) {
                            // An expired or due-soon entry gets a badge at the bottom right, so its row grows by a line.
                            val badged = record.expiryState().let { it == ExpiryState.expired || it == ExpiryState.soon }
                            Box(Modifier.fillMaxWidth()) {
                            Row(Modifier.fillMaxWidth().clickable { if (selecting) toggle() else { viewing = record; editing = false } }.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = if (badged) 32.dp else 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                // Tapping the icon selects; tapping anywhere else opens the entry (or toggles it while selecting).
                                Box(Modifier.size(44.dp).clip(CircleShape).clickable(onClickLabel = if (isSelected) stringResource(R.string.main_deselect) else stringResource(R.string.main_select)) { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); toggle() }, contentAlignment = Alignment.Center) {
                                    when {
                                        selecting -> Icon(if (isSelected) Icons.Default.CheckCircle else Icons.Outlined.Circle, if (isSelected) stringResource(R.string.main_selected) else stringResource(R.string.main_not_selected), Modifier.size(28.dp), tint = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
                                        record.type == RecordType.seed -> IconBadge(Icons.Outlined.AccountBalanceWallet, 44.dp, MaterialTheme.colorScheme.tertiaryContainer, MaterialTheme.colorScheme.onTertiaryContainer)
                                        else -> RecordAvatar(record)
                                    }
                                }
                                Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                                    Text(record.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    if (record.type.tab == RecordType.login && record.group.isNotBlank()) GroupTag(record.group, Modifier.padding(top = 4.dp))
                                }
                                if (record.favorite) Icon(Icons.Default.Star, stringResource(R.string.main_favorite), Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                                if (record.type == RecordType.totp) { if (!selecting) TotpRowCode(totp, now, if (allowCopy) ::copySecret else null) }
                                else if (!selecting) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (badged) Box(Modifier.align(Alignment.BottomEnd).padding(end = 12.dp, bottom = 8.dp)) { ExpiryBadge(record) }
                            }
                        }
                    }
                }
            }
        }
        if (grouping) GroupDialog { grouping = false }
        if (confirmDelete) {
            val doomed = records.filter { it.id in selected }; val seeds = doomed.count { it.type == RecordType.seed }; val totps = doomed.count { it.type == RecordType.totp }
            AlertDialog(onDismissRequest = { confirmDelete = false }, icon = { Icon(Icons.Outlined.Delete, null) }, title = { Text(if (doomed.size == 1) stringResource(R.string.main_delete_title_one, doomed.size) else stringResource(R.string.main_delete_title_many, doomed.size)) },
                text = { HardenWindow(); Text(when { doomed.any { it.ageIdentity != null } -> stringResource(R.string.files_delete_body_keys); totps > 0 -> stringResource(R.string.totp_delete_body_many, totps); seeds == 0 -> stringResource(R.string.main_delete_body); seeds == 1 -> stringResource(R.string.main_delete_body_seed_one, seeds); else -> stringResource(R.string.main_delete_body_seed_many, seeds) }) },
                confirmButton = { TextButton(onClick = { confirmDelete = false; val ids = doomed.map { it.id }.toSet(); val updated = records.filter { it.id !in ids }; work({ engine.save(updated) }) { selected = emptySet(); message = if (ids.size == 1) getString(R.string.main_deleted_one, ids.size) else getString(R.string.main_deleted_many, ids.size) } }) { Text(stringResource(R.string.main_delete), color = MaterialTheme.colorScheme.error) } },
                dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.main_cancel)) } })
        }
    }

    /** A group's name in its own color: colored border, a light tint of that color behind the text, and the normal text color so contrast holds in light and dark themes. */
    @Composable private fun GroupTag(name: String, modifier: Modifier = Modifier, large: Boolean = false) {
        val tint = Color(groupColorArgb(name))
        Surface(modifier, shape = RoundedCornerShape(if (large) 8.dp else 6.dp), color = tint.copy(alpha = 0.18f), border = BorderStroke(1.dp, tint)) {
            Text(name.trim(), Modifier.padding(horizontal = if (large) 10.dp else 6.dp, vertical = if (large) 4.dp else 1.dp), color = MaterialTheme.colorScheme.onSurface,
                style = if (large) MaterialTheme.typography.labelLarge else MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }

    /** Assigns the selected entries to a group. Each row shows whether all (ticked), some (solid) or none (empty) of them are in that group; tapping assigns or clears them all. */
    @Composable private fun GroupDialog(dismiss: () -> Unit) {
        val targets = remember { records.filter { it.id in selected && it.type.tab == RecordType.login } }
        var pending by remember { mutableStateOf(targets.associate { it.id to it.group.trim() }) }
        val allGroups = remember { records.filter { it.type.tab == RecordType.login }.map { it.group.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() } }
        var added by remember { mutableStateOf(emptyList<String>()) }
        var newName by remember { mutableStateOf("") }
        val names = (allGroups + added).distinctBy { it.lowercase() }.sortedBy { it.lowercase() }
        fun assign(name: String) { pending = pending.mapValues { name } }
        fun addGroup() {
            val name = newName.trim(); if (name.isEmpty()) return
            val existing = names.firstOrNull { it.equals(name, ignoreCase = true) } ?: name.also { added = added + it }
            assign(existing); newName = ""
        }
        val changed = targets.filter { pending[it.id] != it.group.trim() }
        AlertDialog(onDismissRequest = dismiss, icon = { Icon(Icons.Outlined.Folder, null) }, title = { Text(if (targets.size == 1) stringResource(R.string.main_group_title_one, targets.size) else stringResource(R.string.main_group_title_many, targets.size)) },
            text = {
                HardenWindow()
                Column {
                    LazyColumn(Modifier.heightIn(max = 280.dp)) {
                        items(names) { name ->
                            val state = groupMembership(pending.values, name)
                            Row(Modifier.fillMaxWidth().clickable { assign(if (state == true) "" else name) }, verticalAlignment = Alignment.CenterVertically) {
                                TriStateCheckbox(when (state) { true -> androidx.compose.ui.state.ToggleableState.On; null -> androidx.compose.ui.state.ToggleableState.Indeterminate; false -> androidx.compose.ui.state.ToggleableState.Off }, onClick = null, modifier = Modifier.padding(12.dp))
                                Box(Modifier.padding(end = 8.dp).size(12.dp).clip(CircleShape).background(Color(groupColorArgb(name))))
                                Text(name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                    OutlinedTextField(newName, { newName = it }, Modifier.fillMaxWidth().padding(top = 8.dp), label = { Text(stringResource(R.string.main_new_group)) }, singleLine = true,
                        trailingIcon = { IconButton(onClick = { addGroup() }, enabled = newName.isNotBlank()) { Icon(Icons.Default.Add, stringResource(R.string.main_add_group)) } })
                }
            },
            confirmButton = { TextButton(enabled = changed.isNotEmpty() || newName.isNotBlank(), onClick = {
                if (newName.isNotBlank()) addGroup()
                val now = java.time.Instant.now().toString()
                val updates = targets.filter { pending[it.id] != it.group.trim() }.associate { it.id to pending.getValue(it.id) }
                dismiss()
                if (updates.isEmpty()) return@TextButton
                val updated = records.map { r -> updates[r.id]?.let { r.copy(group = it, updatedAt = now) } ?: r }
                work({ engine.save(updated) }) { selected = emptySet(); message = if (updates.size == 1) getString(R.string.main_updated_group_one, updates.size) else getString(R.string.main_updated_group_many, updates.size) }
            }) { Text(stringResource(R.string.main_apply)) } },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.main_cancel)) } })
    }
    @Composable private fun RecordScreen(record: VaultRecord, edit: Boolean) {
        if (record.type == RecordType.totp) {
            val isNew = records.none { it.id == record.id }
            if (edit) TotpEditor(record, isNew, records, this, requestCamera = ::withCamera, pickImage = { then -> imageRead = then; if (!launchPicker { imagePicker.launch(arrayOf("image/*")) }) imageRead = null },
                onMigration = { offerMigration(it); viewing = null; editing = false },
                onCancel = { if (isNew) viewing = null else editing = false }, onSave = { saved -> saveRecord(saved) { viewing = saved; editing = false } })
            else TotpDetail(record, if (allowCopy) ::copySecret else null, onBack = { viewing = null }, onEdit = { editing = true },
                onDelete = { val updated = records.filter { it.id != record.id }; work({ engine.save(updated) }) { viewing = null } },
                onToggleFavorite = { val saved = record.copy(favorite = !record.favorite); saveRecord(saved) { viewing = saved } })
        } else if (record.type == RecordType.seed) {
            val isNew = records.none { it.id == record.id }
            if (edit) SeedEditor(record, isNew, onCancel = { if (isNew) viewing = null else editing = false }, onSave = { saved -> saveRecord(saved) { viewing = saved; editing = false } })
            else SeedDetail(record, onBack = { viewing = null }, onEdit = { editing = true },
                onDelete = { val updated = records.filter { it.id != record.id }; work({ engine.save(updated) }) { viewing = null } },
                onToggleFavorite = { val saved = record.copy(favorite = !record.favorite); saveRecord(saved) { viewing = saved } })
        } else if (edit) RecordEditor(record) else RecordDetail(record)
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun RecordDetail(record: VaultRecord) {
        var revealed by remember(record.id) { mutableStateOf(emptySet<String>()) }; var menu by remember { mutableStateOf(false) }; var deleting by remember { mutableStateOf(false) }; var historyFor by remember(record.id) { mutableStateOf<String?>(null) }
        val fileKey = record.ageIdentity != null
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            topBar = { TopAppBar(title = {}, navigationIcon = { IconButton(onClick = { viewing = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.main_back)) } },
                actions = {
                    IconButton(onClick = { val saved = record.copy(favorite = !record.favorite); saveRecord(saved) { viewing = saved } }) { Icon(if (record.favorite) Icons.Default.Star else Icons.Outlined.StarOutline, if (record.favorite) stringResource(R.string.main_remove_favorite) else stringResource(R.string.main_add_favorite), tint = if (record.favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                    // Editing could damage a file key, and with it every file encrypted to it.
                    if (!fileKey) IconButton(onClick = { editing = true }) { Icon(Icons.Outlined.Edit, stringResource(R.string.main_edit)) }
                    Box { IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, stringResource(R.string.main_more)) }
                        DropdownMenu(menu, { menu = false }) { DropdownMenuItem(text = { Text(stringResource(R.string.main_delete_entry)) }, leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = { menu = false; deleting = true }) } }
                }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
            LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                item {
                    Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        RecordAvatar(record, 72.dp)
                        Text(record.name, Modifier.padding(top = 12.dp), style = MaterialTheme.typography.headlineSmall)
                        if (record.website.isNotBlank()) Text(record.website, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                        if (record.type == RecordType.card && record.cardSummary.isNotEmpty()) Text(record.cardSummary, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                        if (record.group.isNotBlank()) GroupTag(record.group, Modifier.padding(top = 8.dp), large = true)
                        record.expiryDate?.let { date ->
                            val expired = record.expiryState() == ExpiryState.expired
                            Text(stringResource(if (expired) R.string.rec_expired_on else R.string.rec_expires_on, formatDate(date)), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodyMedium,
                                color = if (record.expiryState() in setOf(ExpiryState.expired, ExpiryState.soon)) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                if (fileKey) item { Text(stringResource(R.string.files_record_hint), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center) }
                item {
                    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                        if (record.fields.isEmpty()) Text(stringResource(R.string.main_no_fields), Modifier.padding(20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        record.fields.forEachIndexed { index, field ->
                            if (index > 0) HorizontalDivider(Modifier.padding(start = 72.dp), color = MaterialTheme.colorScheme.outlineVariant)
                            val shown = !field.secret || field.id in revealed
                            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                IconBadge(field.icon)
                                Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                                    Text(field.displayName, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    if (field.kind == FieldKind.question && field.question.isNotBlank()) Text(field.question, style = MaterialTheme.typography.bodyMedium)
                                    when {
                                        field.value.isEmpty() -> Text("—", color = MaterialTheme.colorScheme.outline)
                                        shown -> Text(when (field.label) { CARD_NUMBER_LABEL -> Cards.formatted(field.value); CARD_EXPIRY_LABEL -> Cards.formattedExpiry(field.value); else -> field.value }, style = MaterialTheme.typography.bodyLarge, fontFamily = if (field.kind == FieldKind.password) FontFamily.Monospace else null)
                                        else -> Text("••••••••••", style = MaterialTheme.typography.bodyLarge)
                                    }
                                }
                                if (field.secret && field.value.isNotEmpty()) IconButton(onClick = { revealed = if (field.id in revealed) revealed - field.id else revealed + field.id }) { Icon(if (field.id in revealed) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (field.id in revealed) stringResource(R.string.main_hide) else stringResource(R.string.main_reveal)) }
                                if (field.history.isNotEmpty()) IconButton(onClick = { historyFor = field.id }) { Icon(Icons.Outlined.History, stringResource(R.string.main_password_history_for, field.displayName)) }
                                if (allowCopy && field.value.isNotEmpty()) IconButton(onClick = { copySecret(if (field.label == CARD_EXPIRY_LABEL) Cards.formattedExpiry(field.value) else field.value) }) { Icon(Icons.Outlined.ContentCopy, stringResource(R.string.main_copy_field, field.displayName)) }
                            }
                        }
                    }
                }
                formatUpdated(record.updatedAt)?.let { item { Text(stringResource(R.string.main_updated_at, it), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center) } }
            }
        }
        record.fields.firstOrNull { it.id == historyFor }?.let { field -> PasswordHistorySheet(field) { historyFor = null } }
        if (deleting) AlertDialog(onDismissRequest = { deleting = false }, icon = { Icon(Icons.Outlined.Delete, null) }, title = { Text(stringResource(R.string.main_delete_this_entry)) }, text = { HardenWindow(); Text(if (fileKey) stringResource(R.string.files_delete_key_body, record.name) else stringResource(R.string.main_delete_this_entry_body, record.name)) },
            confirmButton = { TextButton(onClick = { deleting = false; val updated = records.filter { it.id != record.id }; work({ engine.save(updated) }) { viewing = null } }) { Text(stringResource(R.string.main_delete)) } },
            dismissButton = { TextButton(onClick = { deleting = false }) { Text(stringResource(R.string.main_cancel)) } })
    }

    /** Earlier values of a password, newest change first. Imported from Password Keeper; unrelated to fields the user names "Previous password". */
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun PasswordHistorySheet(field: VaultField, dismiss: () -> Unit) {
        val entries = remember(field.id, field.history) { field.historyNewestFirst }
        var shown by remember { mutableStateOf(emptySet<Int>()) }
        ModalBottomSheet(onDismissRequest = dismiss) {
            HardenWindow()
            Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
                Text(stringResource(R.string.main_password_history), style = MaterialTheme.typography.titleLarge)
                Text(stringResource(R.string.main_history_subtitle, field.displayName), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
                LazyColumn { itemsIndexed(entries) { index, change ->
                    if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(if (change.changedAtEpochSeconds > 0) formatEpoch(change.changedAtEpochSeconds) ?: stringResource(R.string.main_unknown_date) else stringResource(R.string.main_unknown_date), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(if (index in shown) change.value else "••••••••••", fontFamily = if (index in shown) FontFamily.Monospace else null)
                        }
                        IconButton(onClick = { shown = if (index in shown) shown - index else shown + index }) { Icon(if (index in shown) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (index in shown) stringResource(R.string.main_hide) else stringResource(R.string.main_reveal)) }
                        if (allowCopy) IconButton(onClick = { copySecret(change.value) }) { Icon(Icons.Outlined.ContentCopy, stringResource(R.string.main_copy_earlier_password)) }
                    }
                } }
            }
        }
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun RecordEditor(initial: VaultRecord) {
        val isNew = records.none { it.id == initial.id }
        var record by remember(initial.id) { mutableStateOf(initial) }; var revealed by remember { mutableStateOf(emptySet<String>()) }; var menu by remember { mutableStateOf(false) }
        var generatingFor by remember { mutableStateOf<String?>(null) }
        val listState = rememberLazyListState(); val haptics = LocalHapticFeedback.current
        var draggingId by remember { mutableStateOf<String?>(null) }; var dragOffset by remember { mutableFloatStateOf(0f) }
        fun cancel() { if (isNew) viewing = null else editing = false }
        fun update(field: VaultField) { record = record.copy(fields = record.fields.map { if (it.id == field.id) field else it }) }
        fun move(id: String, direction: Int) { val index = record.fields.indexOfFirst { it.id == id }; val target = index + direction; if (index >= 0 && target in record.fields.indices) record = record.copy(fields = record.fields.toMutableList().apply { add(target, removeAt(index)) }) }
        // Swap with the adjacent field once the dragged card's edge passes that neighbour's midpoint, then
        // compensate the offset so the card stays under the finger after the list re-lays out.
        fun drag(dy: Float) {
            val id = draggingId ?: return
            dragOffset += dy
            val items = listState.layoutInfo.visibleItemsInfo
            val current = items.firstOrNull { it.key == id } ?: return
            val ids = record.fields.map { it.id }
            val down = dragOffset > 0
            val neighbour = items.firstOrNull { it.index == current.index + (if (down) 1 else -1) && (it.key as? String) in ids } ?: return
            val crossed = if (down) current.offset + current.size + dragOffset > neighbour.offset + neighbour.size / 2f else current.offset + dragOffset < neighbour.offset + neighbour.size / 2f
            if (!crossed) return
            move(id, if (down) 1 else -1)
            dragOffset -= (if (down) (neighbour.offset + neighbour.size) - (current.offset + current.size) else neighbour.offset - current.offset).toFloat()
            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        }
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            topBar = { TopAppBar(title = { Text(stringResource(when (record.type) {
                RecordType.card -> if (isNew) R.string.rec_new_card_title else R.string.rec_edit_card
                RecordType.note -> if (isNew) R.string.rec_new_note_title else R.string.rec_edit_note
                else -> if (isNew) R.string.main_new_entry else R.string.main_edit_entry
            })) }, navigationIcon = { IconButton(onClick = { cancel() }) { Icon(Icons.Default.Close, stringResource(R.string.main_discard_changes)) } },
                actions = {
                    IconButton(onClick = { record = record.copy(favorite = !record.favorite) }) { Icon(if (record.favorite) Icons.Default.Star else Icons.Outlined.StarOutline, if (record.favorite) stringResource(R.string.main_remove_favorite) else stringResource(R.string.main_add_favorite), tint = if (record.favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                    Button(onClick = { val saved = record.copy(name = record.name.trim(), updatedAt = Instant.now().toString()).recordingPasswordChanges(records.firstOrNull { it.id == record.id }); saveRecord(saved) { viewing = saved; editing = false } }, enabled = record.name.isNotBlank(), modifier = Modifier.padding(end = 8.dp)) { Text(stringResource(R.string.main_save)) }
                }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
            LazyColumn(Modifier.padding(padding), state = listState, contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item(key = "details") {
                    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            EditorField(record.name, { record = record.copy(name = it) }, stringResource(R.string.main_name), Icons.Outlined.Badge)
                            if (record.type != RecordType.note) EditorField(record.website, { record = record.copy(website = it) }, stringResource(R.string.main_website), Icons.Outlined.Language, KeyboardType.Uri)
                            GroupField(record.group) { record = record.copy(group = it) }
                            // A card's own expiry date is its reminder.
                            if (record.type != RecordType.card) ExpiryField(record.expires) { record = record.copy(expires = it) }
                        }
                    }
                }
                item(key = "fields-title") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SectionTitle(stringResource(R.string.main_fields), Modifier.weight(1f))
                        if (record.fields.size > 1) Text(stringResource(R.string.main_drag_to_reorder), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                items(record.fields, key = { it.id }) { field ->
                    val dragging = draggingId == field.id
                    val index = record.fields.indexOfFirst { it.id == field.id }
                    val elevation by animateDpAsState(if (dragging) 16.dp else 0.dp, label = "lift")
                    val scale by animateFloatAsState(if (dragging) 1.03f else 1f, label = "scale")
                    val container by animateColorAsState(if (dragging) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerLow, label = "container")
                    val shape = RoundedCornerShape(16.dp)
                    val moveUpLabel = stringResource(R.string.main_move_up); val moveDownLabel = stringResource(R.string.main_move_down)
                    Card(
                        modifier = Modifier
                            .then(if (dragging) Modifier.zIndex(1f).graphicsLayer { translationY = dragOffset } else Modifier.animateItem(fadeInSpec = null, fadeOutSpec = null, placementSpec = spring(stiffness = Spring.StiffnessMediumLow)))
                            .graphicsLayer { scaleX = scale; scaleY = scale }
                            .shadow(elevation, shape)
                            .semantics { customActions = listOf(CustomAccessibilityAction(moveUpLabel) { move(field.id, -1); true }, CustomAccessibilityAction(moveDownLabel) { move(field.id, 1); true }) },
                        shape = shape, colors = CardDefaults.cardColors(containerColor = container),
                        border = if (dragging) BorderStroke(2.dp, MaterialTheme.colorScheme.primary) else null,
                    ) {
                        Row(Modifier.padding(start = 12.dp, top = 8.dp, bottom = 12.dp), verticalAlignment = Alignment.Top) {
                            Box(Modifier.padding(top = 8.dp)) { IconBadge(field.icon, 36.dp) }
                            Column(Modifier.weight(1f).padding(start = 12.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(field.displayName, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    IconButton(onClick = { record = record.copy(fields = record.fields.filter { it.id != field.id }) }, modifier = Modifier.size(36.dp)) { Icon(Icons.Outlined.RemoveCircleOutline, stringResource(R.string.main_remove_field, field.displayName), Modifier.size(20.dp), tint = MaterialTheme.colorScheme.error) }
                                }
                                if (field.kind == FieldKind.question) { EditorField(field.question, { update(field.copy(question = it)) }, stringResource(R.string.main_question)); Spacer(Modifier.height(8.dp)) }
                                val hidden = field.secret && field.id !in revealed
                                // A card number or expiry is stored as digits only and shown grouped; legacy values like "03/27" are edited as their digits.
                                val cardInput = CardInput.of(field.label)?.takeIf { it.digits(field.value) != null }
                                val editorText = cardInput?.digits(field.value) ?: field.value
                                var text by remember(field.id) { mutableStateOf(TextFieldValue(editorText, TextRange(editorText.length))) }
                                if (text.text != editorText) text = TextFieldValue(editorText, TextRange(editorText.length))
                                OutlinedTextField(text, { typed ->
                                    val value = cardInput?.clean(typed.text) ?: typed.text
                                    // When cleaning changed what was typed (3 → 03, a pasted space dropped), the cursor goes to the end.
                                    text = if (value == typed.text) typed else TextFieldValue(value, TextRange(value.length))
                                    if (value != editorText) update(field.copy(value = value))
                                }, Modifier.fillMaxWidth(), placeholder = { Text(when { field.kind == FieldKind.question -> stringResource(R.string.main_answer); field.label == CARD_EXPIRY_LABEL -> stringResource(R.string.rec_expiry_placeholder); else -> field.displayName }) },
                                    singleLine = field.kind != FieldKind.note, shape = RoundedCornerShape(12.dp), textStyle = if (field.kind == FieldKind.password && !hidden) LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace) else LocalTextStyle.current,
                                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = when { field.label in CARD_NUMERIC_LABELS -> KeyboardType.NumberPassword; cardInput == CardInput.expiry -> KeyboardType.Number; field.secret -> KeyboardType.Password; else -> KeyboardType.Text }),
                                    visualTransformation = when { hidden -> PasswordVisualTransformation(); cardInput != null -> CardDigitsTransformation(cardInput); else -> VisualTransformation.None },
                                    trailingIcon = { if (field.secret) Row {
                                        if (field.kind == FieldKind.password && field.label !in CARD_NUMERIC_LABELS) IconButton(onClick = { generatingFor = field.id }) { Icon(Icons.Outlined.AutoAwesome, stringResource(R.string.main_generate_password)) }
                                        IconButton(onClick = { revealed = if (field.id in revealed) revealed - field.id else revealed + field.id }) { Icon(if (hidden) Icons.Outlined.Visibility else Icons.Outlined.VisibilityOff, if (hidden) stringResource(R.string.main_reveal) else stringResource(R.string.main_hide)) }
                                    } })
                            }
                            // Handle: dragging starts immediately here, so the rest of the card still scrolls normally.
                            Box(Modifier.padding(top = 40.dp).size(48.dp).pointerInput(field.id) {
                                detectVerticalDragGestures(
                                    onDragStart = { draggingId = field.id; dragOffset = 0f; haptics.performHapticFeedback(HapticFeedbackType.LongPress) },
                                    onDragEnd = { draggingId = null; dragOffset = 0f }, onDragCancel = { draggingId = null; dragOffset = 0f },
                                    onVerticalDrag = { change, dy -> change.consume(); drag(dy) })
                            }, contentAlignment = Alignment.Center) { Icon(Icons.Default.DragIndicator, stringResource(R.string.main_reorder_field, field.displayName, index + 1, record.fields.size), tint = if (dragging) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    }
                }
                item(key = "add") {
                    Box {
                        OutlinedButton(onClick = { menu = true }, Modifier.fillMaxWidth().height(48.dp)) { Icon(Icons.Default.Add, null); Text("  " + stringResource(R.string.main_add_field)) }
                        DropdownMenu(menu, { menu = false }) { FieldKind.entries.forEach { kind -> DropdownMenuItem(text = { Text(stringResource(kind.defaultLabelRes)) }, leadingIcon = { Icon(kind.icon, null) }, onClick = { record = record.copy(fields = record.fields + VaultField(kind = kind, label = kind.defaultLabel)); menu = false }) } }
                    }
                }
            }
        }
        generatingFor?.let { id -> GeneratorDialog(generatorOptions, onDismiss = { generatingFor = null }, onUse = { value -> record.fields.firstOrNull { it.id == id }?.let { update(it.copy(value = value)) }; revealed = revealed + id; generatingFor = null }) }
    }
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun GroupField(value: String, change: (String) -> Unit) {
        val groups = remember(records) { records.filter { it.type.tab == RecordType.login }.map { it.group.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() }.sortedBy { it.lowercase() } }
        var expanded by remember { mutableStateOf(false) }
        val typed = value.trim()
        // Typing narrows the list to matching groups; opening it with the arrow always lists every group, and picking one replaces the current group.
        var showAll by remember { mutableStateOf(false) }
        val options = if (showAll || typed.isEmpty()) groups else groups.filter { it.contains(typed, ignoreCase = true) && !it.equals(typed, ignoreCase = true) }
        ExposedDropdownMenuBox(expanded && options.isNotEmpty(), { expanded = it; if (it) showAll = true }) {
            OutlinedTextField(value, { change(it); showAll = false; expanded = true }, Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryEditable), label = { Text(stringResource(R.string.main_group)) }, leadingIcon = { Icon(Icons.Outlined.Folder, null) },
                trailingIcon = { if (groups.isNotEmpty()) ExposedDropdownMenuDefaults.TrailingIcon(expanded && options.isNotEmpty(), Modifier.menuAnchor(ExposedDropdownMenuAnchorType.SecondaryEditable)) },
                supportingText = if (groups.isNotEmpty() && typed.isNotEmpty() && groups.none { it.equals(typed, ignoreCase = true) }) { { Text(stringResource(R.string.main_new_group)) } } else null,
                singleLine = true, shape = RoundedCornerShape(12.dp), keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
            ExposedDropdownMenu(expanded && options.isNotEmpty(), { expanded = false }) {
                options.forEach { name -> DropdownMenuItem(text = { Text(name) }, leadingIcon = { Icon(Icons.Outlined.Folder, null) }, onClick = { change(name); expanded = false }, contentPadding = ExposedDropdownMenuDefaults.ItemContentPadding) }
            }
        }
    }
    @Composable private fun EditorField(value: String, change: (String) -> Unit, label: String, icon: androidx.compose.ui.graphics.vector.ImageVector? = null, keyboard: KeyboardType = KeyboardType.Text) {
        OutlinedTextField(value, change, Modifier.fillMaxWidth(), label = { Text(label) }, leadingIcon = icon?.let { { Icon(it, null) } }, singleLine = true, shape = RoundedCornerShape(12.dp), keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = keyboard))
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun SettingsScreen() {
        var dialog by this::settingsDialog
        @Composable fun Row(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String? = null, trailing: (@Composable () -> Unit)? = null, onClick: () -> Unit) =
            ListItem(headlineContent = { Text(title) }, supportingContent = subtitle?.let { { Text(it) } }, leadingContent = { IconBadge(icon) }, trailingContent = trailing,
                modifier = Modifier.clickable(onClick = onClick), colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent))
        @Composable fun Group(content: @Composable ColumnScope.() -> Unit) = Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) { Column(Modifier.padding(vertical = 4.dp), content = content) }
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            topBar = { TopAppBar(title = { Text(stringResource(R.string.main_settings)) }, navigationIcon = { IconButton(onClick = { settings = false }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.main_back)) } }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
            Column(Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
                SectionTitle(stringResource(R.string.main_appearance))
                Group {
                    Column(Modifier.padding(16.dp)) {
                        Text(stringResource(R.string.main_theme), style = MaterialTheme.typography.bodyLarge); Spacer(Modifier.height(12.dp))
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                            ThemeMode.entries.forEachIndexed { i, mode ->
                                SegmentedButton(themeMode == mode, { themeMode = mode; prefs.edit().putString("theme", mode.name).apply() }, SegmentedButtonDefaults.itemShape(i, ThemeMode.entries.size)) { Text(stringResource(mode.labelRes)) }
                            }
                        }
                    }
                    Row(Icons.Outlined.Language, stringResource(R.string.main_language), stringResource(languageName(language))) { dialog = SettingsDialog.LanguageChoice }
                }
                SectionTitle(stringResource(R.string.main_security))
                Group {
                    val report = remember(records) { VaultHealth.check(records) }
                    Row(Icons.Outlined.HealthAndSafety, stringResource(R.string.health_title), report.score?.let { stringResource(R.string.health_summary, it, report.problemCount) } ?: stringResource(R.string.health_nothing)) { openHealth() }
                    Row(Icons.Outlined.Timer, stringResource(R.string.main_auto_lock), stringResource(autoLock.labelRes)) { dialog = SettingsDialog.AutoLockChoice }
                    // Biometrics always open the real vault, so the decoy vault neither shows nor changes them.
                    if (!decoySession) Row(Icons.Outlined.Fingerprint, stringResource(R.string.main_biometric_unlock), if (biometricEnabled) stringResource(R.string.main_on) else stringResource(R.string.main_off), trailing = { Switch(biometricEnabled, { on -> if (on) dialog = SettingsDialog.EnableBiometrics else disableBiometrics() }) }) {
                        if (biometricEnabled) disableBiometrics() else dialog = SettingsDialog.EnableBiometrics
                    }
                    if (autofillManager?.isAutofillSupported == true) Row(Icons.Outlined.Keyboard, stringResource(R.string.autofill_setting), stringResource(if (autofillEnabled) R.string.autofill_setting_on else R.string.autofill_setting_off),
                        trailing = { androidx.compose.foundation.layout.Row(verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = { dialog = SettingsDialog.AutofillHelp }) { Icon(Icons.Outlined.Info, stringResource(R.string.autofill_help_title)) }; Switch(autofillEnabled, { setAutofill(it) }) } }) { setAutofill(!autofillEnabled) }
                    Row(Icons.Outlined.Password, stringResource(R.string.main_change_app_password)) { dialog = SettingsDialog.ChangePassword }
                    if (!decoySession) Row(Icons.Outlined.TheaterComedy, stringResource(R.string.decoy_title), if (decoyEnabled) stringResource(R.string.main_on) else stringResource(R.string.main_off)) { dialog = if (decoyEnabled) SettingsDialog.DecoyManage else SettingsDialog.DecoySetup }
                    Row(EncryptedFileIcon, stringResource(R.string.files_title), stringResource(R.string.files_settings_summary)) { fileCrypt = true }
                }
                SectionTitle(stringResource(R.string.main_random_password))
                Group {
                    val o = generatorOptions; val letters = stringResource(R.string.main_letters); val numbers = stringResource(R.string.main_numbers); val symbols = stringResource(R.string.main_symbols)
                    Row(Icons.Outlined.AutoAwesome, stringResource(R.string.main_password_generator), stringResource(R.string.main_generator_summary, o.length, listOfNotNull(letters.takeIf { o.letters }, numbers.takeIf { o.numbers }, symbols.takeIf { o.symbols }).joinToString(stringResource(R.string.main_list_separator)))) { dialog = SettingsDialog.Generator }
                }
                SectionTitle(stringResource(R.string.main_clipboard))
                Group {
                    Row(Icons.Outlined.ContentCopy, stringResource(R.string.main_allow_copying), stringResource(R.string.main_allow_copying_summary), trailing = { Switch(allowCopy, { updateAllowCopy(it) }) }) { updateAllowCopy(!allowCopy) }
                    if (allowCopy) {
                        Row(Icons.Outlined.AvTimer, stringResource(R.string.main_clear_copied_text), if (clipboardClear.millis == null) stringResource(R.string.main_never) else stringResource(R.string.main_after_time, stringResource(clipboardClear.labelRes))) { dialog = SettingsDialog.ClipboardChoice }
                        Row(Icons.Outlined.LockClock, stringResource(R.string.main_clear_on_lock), stringResource(R.string.main_clear_on_lock_summary), trailing = { Switch(clearClipOnLock, { updateClearOnLock(it) }) }) { updateClearOnLock(!clearClipOnLock) }
                    }
                }
                SectionTitle(stringResource(R.string.main_backup_migration))
                Group {
                    Row(Icons.Outlined.History, stringResource(R.string.backup_last_title), lastBackup?.let { stringResource(R.string.backup_last_value, formatUpdated(it.toString()).orEmpty(), backupAge(it)) } ?: stringResource(R.string.backup_never)) { dialog = SettingsDialog.Exporting(Export.encrypted) }
                    Row(Icons.Outlined.NotificationsActive, stringResource(R.string.backup_reminder_title), stringResource(backupInterval.labelRes)) { dialog = SettingsDialog.BackupReminderChoice }
                    Row(Icons.Outlined.FileOpen, stringResource(R.string.main_import_action), stringResource(R.string.main_import_row_summary)) { launchPicker { importPicker.launch(arrayOf("*/*")) } }
                    Row(Icons.Outlined.SendToMobile, stringResource(R.string.transfer_send), stringResource(R.string.transfer_send_summary)) { dialog = SettingsDialog.TransferSend }
                    Row(Icons.Outlined.QrCodeScanner, stringResource(R.string.transfer_receive), stringResource(R.string.transfer_receive_summary)) { withCamera { receiving = true } }
                    Row(Icons.Outlined.EnhancedEncryption, stringResource(R.string.main_export_encrypted), stringResource(R.string.main_export_encrypted_summary)) { dialog = SettingsDialog.Exporting(Export.encrypted) }
                    Row(Icons.Outlined.Description, stringResource(R.string.main_export_csv), stringResource(R.string.main_export_csv_summary)) { dialog = SettingsDialog.Exporting(Export.csv) }
                }
                updates?.ui?.let { update ->
                    SectionTitle(stringResource(R.string.update_title))
                    UpdateRow(update)
                }
                Text(stringResource(R.string.main_attempts_note), Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        when (val d = dialog) {
            null -> {}
            SettingsDialog.LanguageChoice -> AlertDialog(onDismissRequest = { dialog = null }, icon = { Icon(Icons.Outlined.Language, null) }, title = { Text(stringResource(R.string.main_language)) },
                text = { Column {
                    LANGUAGES.forEach { tag -> androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().selectable(language == tag, onClick = { dialog = null; if (language != tag) { language = tag; prefs.edit().putString("language", tag).apply(); recreate() } }).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) { RadioButton(language == tag, null); Text("  " + stringResource(languageName(tag))) } }
                } }, confirmButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.main_close)) } })
            SettingsDialog.AutoLockChoice -> AlertDialog(onDismissRequest = { dialog = null }, icon = { Icon(Icons.Outlined.Timer, null) }, title = { Text(stringResource(R.string.main_auto_lock)) },
                text = { Column {
                    Text(stringResource(R.string.main_autolock_body), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant); Spacer(Modifier.height(8.dp))
                    AutoLock.entries.forEach { option -> androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().selectable(autoLock == option, onClick = { autoLock = option; prefs.edit().putString("autoLock", option.name).apply(); dialog = null }).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) { RadioButton(autoLock == option, null); Text("  " + stringResource(option.labelRes)) } }
                } }, confirmButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.main_close)) } })
            SettingsDialog.BackupReminderChoice -> AlertDialog(onDismissRequest = { dialog = null }, icon = { Icon(Icons.Outlined.NotificationsActive, null) }, title = { Text(stringResource(R.string.backup_reminder_title)) },
                text = { Column {
                    Text(stringResource(R.string.backup_reminder_body), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant); Spacer(Modifier.height(8.dp))
                    BackupInterval.entries.forEach { option -> androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().selectable(backupInterval == option, onClick = { backups.interval = option; loadBackupStatus(); dialog = null }).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) { RadioButton(backupInterval == option, null); Text("  " + stringResource(option.labelRes)) } }
                } }, confirmButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.main_close)) } })
            SettingsDialog.ClipboardChoice -> AlertDialog(onDismissRequest = { dialog = null }, icon = { Icon(Icons.Outlined.AvTimer, null) }, title = { Text(stringResource(R.string.main_clear_copied_text)) },
                text = { Column(Modifier.verticalScroll(rememberScrollState())) {
                    ClipboardClear.entries.forEach { option -> androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().selectable(clipboardClear == option, onClick = { clipboardClear = option; prefs.edit().putString("clipboardClear", option.name).apply(); dialog = null }).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) { RadioButton(clipboardClear == option, null); Text("  " + stringResource(option.labelRes)) } }
                } }, confirmButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.main_close)) } })
            SettingsDialog.Generator -> AlertDialog(onDismissRequest = { dialog = null }, icon = { Icon(Icons.Outlined.AutoAwesome, null) }, title = { Text(stringResource(R.string.main_random_password)) },
                text = { Column { Text(stringResource(R.string.main_generator_defaults), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant); Spacer(Modifier.height(12.dp))
                    GeneratorOptionsEditor(generatorOptions) { o -> generatorOptions = o; prefs.edit().putInt("genLength", o.length).putBoolean("genLetters", o.letters).putBoolean("genNumbers", o.numbers).putBoolean("genSymbols", o.symbols).apply() } } },
                confirmButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.main_done)) } })
            SettingsDialog.EnableBiometrics -> PasswordDialog(Icons.Outlined.Fingerprint, stringResource(R.string.main_enable_biometric_unlock), stringResource(R.string.main_enable_biometric_body), stringResource(R.string.main_continue_action), { dialog = null }) { biometrics(it) }
            SettingsDialog.ChangePassword -> ChangePasswordDialog { dialog = null }
            SettingsDialog.DecoySetup -> DecoySetupDialog(reset = false) { dialog = null }
            SettingsDialog.DecoyReset -> DecoySetupDialog(reset = true) { dialog = null }
            // Browsers keep their own switch for handing forms to an autofill service; without it PassVault is never asked.
            SettingsDialog.AutofillHelp -> AlertDialog(onDismissRequest = { dialog = null }, icon = { Icon(Icons.Outlined.Info, null) }, title = { Text(stringResource(R.string.autofill_help_title)) },
                text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.autofill_help_step_service)); Text(stringResource(R.string.autofill_help_step_chrome)); Text(stringResource(R.string.autofill_help_step_use))
                    Text(stringResource(R.string.autofill_help_other_browsers), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } }, confirmButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.main_close)) } })
            SettingsDialog.DecoyManage -> {
                val canReset = decoyResettable
                AlertDialog(onDismissRequest = { dialog = null }, icon = { Icon(Icons.Outlined.TheaterComedy, null) }, title = { Text(stringResource(R.string.decoy_title)) },
                    text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(R.string.decoy_manage_body), style = MaterialTheme.typography.bodyMedium)
                        OutlinedButton(onClick = { dialog = SettingsDialog.DecoyReset }, Modifier.fillMaxWidth(), enabled = canReset) { Icon(Icons.Outlined.Password, null); Text("  " + stringResource(R.string.decoy_change_password)) }
                        if (!canReset) Text(stringResource(R.string.decoy_change_unavailable), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        OutlinedButton(onClick = { dialog = SettingsDialog.DecoyRemove }, Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Delete, null); Text("  " + stringResource(R.string.decoy_remove)) }
                    } },
                    confirmButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.main_close)) } })
            }
            SettingsDialog.TransferSend -> PasswordDialog(Icons.Outlined.SendToMobile, stringResource(R.string.transfer_send), stringResource(R.string.transfer_send_body), stringResource(R.string.main_continue_action), { dialog = null }) { pass ->
                var sealed: Pair<String, ByteArray>? = null
                work({ sealed = engine.exportTransfer(pass); null }) { sealed?.let { (code, bytes) -> sending = PendingTransfer(code, bytes, fileVault(), SystemClock.elapsedRealtime() + TRANSFER_KEEP_MILLIS) } }
            }
            SettingsDialog.DecoyRemove -> PasswordDialog(Icons.Outlined.TheaterComedy, stringResource(R.string.decoy_remove), stringResource(R.string.decoy_remove_body), stringResource(R.string.main_delete), { dialog = null }) { pass ->
                work({ engine.removeDecoy(pass); clearVaultHistory(true); null }) { decoyEnabled = false; decoyResettable = false; message = getString(R.string.decoy_removed) }
            }
            is SettingsDialog.Exporting -> {
                var consent by remember { mutableStateOf(false) }
                val csv = d.kind == Export.csv
                PasswordDialog(if (csv) Icons.Outlined.Description else Icons.Outlined.EnhancedEncryption, if (csv) stringResource(R.string.main_export_csv) else stringResource(R.string.main_export_encrypted),
                    if (csv) stringResource(R.string.main_export_csv_body) else stringResource(R.string.main_export_encrypted_body),
                    stringResource(R.string.main_export_action), { dialog = null }, enabled = !csv || consent,
                    extra = { if (csv) {
                        Text(stringResource(R.string.main_csv_warning), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                        CheckRow(consent, { consent = it }) { Text(stringResource(R.string.main_understand_risk), style = MaterialTheme.typography.bodyMedium) }
                    } }) { pass ->
                    prepareExport(pass, csv)
                }
            }
        }
    }
    @Composable private fun UpdateRow(update: UpdateUi) {
        val status = when (update.phase) {
            UpdatePhase.IDLE -> stringResource(R.string.update_idle)
            UpdatePhase.CHECKING -> stringResource(R.string.update_checking)
            UpdatePhase.CURRENT -> stringResource(R.string.update_current)
            UpdatePhase.AVAILABLE -> if (update.source == UpdateSource.PLAY) stringResource(R.string.update_available_play) else stringResource(R.string.update_available, update.version.orEmpty())
            UpdatePhase.DOWNLOADING -> stringResource(R.string.update_downloading, update.percent)
            UpdatePhase.PERMISSION -> stringResource(R.string.update_permission)
            UpdatePhase.INSTALLING -> stringResource(R.string.update_installing)
            UpdatePhase.ERROR -> stringResource(R.string.update_error)
        }
        val install = update.phase in setOf(UpdatePhase.AVAILABLE, UpdatePhase.PERMISSION) || (update.phase == UpdatePhase.ERROR && update.version != null)
        val enabled = update.phase !in setOf(UpdatePhase.CHECKING, UpdatePhase.DOWNLOADING, UpdatePhase.INSTALLING)
        Column(Modifier.padding(16.dp)) {
            Text(stringResource(R.string.update_version, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE, when (update.source) { UpdateSource.PLAY -> "Google Play"; UpdateSource.LAN -> stringResource(R.string.update_source_lan); UpdateSource.GITHUB -> "GitHub" }), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(4.dp)); Text(status, style = MaterialTheme.typography.bodyLarge)
            if (update.phase == UpdatePhase.DOWNLOADING) { Spacer(Modifier.height(8.dp)); LinearProgressIndicator(progress = { update.percent / 100f }, Modifier.fillMaxWidth()) }
            Spacer(Modifier.height(12.dp))
            Button(onClick = { if (install) updates?.update() else updates?.check(true) }, enabled = enabled) {
                Text(stringResource(when {
                    update.phase == UpdatePhase.AVAILABLE -> R.string.update_now
                    update.phase == UpdatePhase.PERMISSION -> R.string.update_continue
                    update.phase == UpdatePhase.ERROR && update.version != null -> R.string.update_retry
                    else -> R.string.update_check
                }))
            }
        }
    }
    @Composable private fun PasswordDialog(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, body: String, confirm: String, dismiss: () -> Unit, enabled: Boolean = true, extra: @Composable ColumnScope.() -> Unit = {}, submit: (String) -> Unit) {
        var password by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = dismiss, icon = { Icon(icon, null) }, title = { Text(title) },
            text = { HardenWindow(); Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { Text(body); SecretInput(stringResource(R.string.main_app_password), password, { password = it }); extra() } },
            confirmButton = { TextButton(onClick = { val value = password; password = ""; dismiss(); submit(value) }, enabled = enabled && password.isNotEmpty()) { Text(confirm) } },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.main_cancel)) } })
    }
    @Composable private fun ChangePasswordDialog(dismiss: () -> Unit) {
        var current by remember { mutableStateOf("") }; var next by remember { mutableStateOf("") }; var repeat by remember { mutableStateOf("") }
        val problem = passwordProblem(next)
        AlertDialog(onDismissRequest = dismiss, icon = { Icon(Icons.Outlined.Password, null) }, title = { Text(stringResource(R.string.main_change_app_password)) },
            text = { HardenWindow(); Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SecretInput(stringResource(R.string.main_current_password), current, { current = it }); SecretInput(stringResource(R.string.main_new_password), next, { next = it }); SecretInput(stringResource(R.string.main_repeat_new_password), repeat, { repeat = it })
                PasswordHint(next, problem)
                if (repeat.isNotEmpty() && !samePassword(next, repeat)) Text(stringResource(R.string.main_passwords_dont_match), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                Text(stringResource(R.string.main_existing_backups_keep), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } },
            confirmButton = { TextButton(onClick = { val c = current; val n = next; val hadBiometric = biometricEnabled; val decoy = decoySession; current = ""; next = ""; repeat = ""; dismiss()
                // The decoy's password change leaves the real vault's biometric key alone, and must not mention it.
                work({ engine.changePassword(c, n); null }) { if (!decoy) biometricEnabled = false; message = getString(if (hadBiometric && !decoy) R.string.main_app_password_changed_biometric_off else R.string.main_app_password_changed) } }, enabled = current.isNotEmpty() && problem == null && samePassword(next, repeat)) { Text(stringResource(R.string.main_change)) } },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.main_cancel)) } })
    }
    /** Sets up the decoy vault, or with [reset] gives the existing one a new password (its contents are kept). */
    @Composable private fun DecoySetupDialog(reset: Boolean, dismiss: () -> Unit) {
        var current by remember { mutableStateOf("") }; var decoy by remember { mutableStateOf("") }; var repeat by remember { mutableStateOf("") }
        val problem = passwordProblem(decoy)
        AlertDialog(onDismissRequest = dismiss, icon = { Icon(Icons.Outlined.TheaterComedy, null) }, title = { Text(stringResource(if (reset) R.string.decoy_change_password else R.string.decoy_title)) },
            text = { HardenWindow(); Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(if (reset) R.string.decoy_change_body else R.string.decoy_body), style = MaterialTheme.typography.bodyMedium)
                SecretInput(stringResource(R.string.main_app_password), current, { current = it }); SecretInput(stringResource(if (reset) R.string.decoy_new_password else R.string.decoy_password), decoy, { decoy = it }); SecretInput(stringResource(R.string.decoy_repeat), repeat, { repeat = it })
                PasswordHint(decoy, problem)
                if (repeat.isNotEmpty() && !samePassword(decoy, repeat)) Text(stringResource(R.string.main_passwords_dont_match), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            } },
            confirmButton = { TextButton(onClick = { val c = current; val d = decoy; current = ""; decoy = ""; repeat = ""; dismiss()
                if (reset) work({ engine.resetDecoyPassword(c, d); null }) { message = getString(R.string.decoy_password_changed) }
                else work({ engine.createDecoy(c, d); null }) { decoyEnabled = true; decoyResettable = true; message = getString(R.string.decoy_created) } },
                enabled = current.isNotEmpty() && problem == null && samePassword(decoy, repeat)) { Text(stringResource(if (reset) R.string.main_change else R.string.decoy_create)) } },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.main_cancel)) } })
    }
    @Composable private fun ImportDialogs() {
        scannedImport?.let { scan ->
            AlertDialog(onDismissRequest = { scannedImport = null }, icon = { Icon(Icons.Outlined.QrCodeScanner, null) },
                title = { Text(if (scan.records.isEmpty()) stringResource(R.string.totp_import_nothing) else stringResource(R.string.totp_import_title, scan.records.size)) },
                text = { HardenWindow(); Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (scan.records.isNotEmpty()) { Text(stringResource(R.string.totp_import_body)); Text(scan.records.joinToString(", ") { it.name }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    if (scan.duplicates > 0) Text(stringResource(R.string.totp_import_skipped_dupes, scan.duplicates), style = MaterialTheme.typography.bodySmall)
                    if (scan.hotp > 0) Text(stringResource(R.string.totp_import_skipped_hotp, scan.hotp), style = MaterialTheme.typography.bodySmall)
                    Text(stringResource(R.string.totp_import_batch), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } },
                confirmButton = { if (scan.records.isNotEmpty()) TextButton(onClick = { scannedImport = null; work({ engine.merge(scan.records) }) { tab = RecordType.totp; message = getString(R.string.totp_added, scan.records.size) } }) { Text(stringResource(R.string.totp_add_action)) } else TextButton(onClick = { scannedImport = null }) { Text(stringResource(R.string.main_ok)) } },
                dismissButton = { if (scan.records.isNotEmpty()) TextButton(onClick = { scannedImport = null }) { Text(stringResource(R.string.main_cancel)) } })
        }
        if (importBytes != null) {
            var backupPassword by remember { mutableStateOf("") }
            val keeper = importBytes?.let { Pkb2.isPkb2(it) } == true; val keepass = importBytes?.let { Kdbx.isKdbx(it) } == true; val transfer = importBytes?.let { Transfer.isTransfer(it) } == true
            fun discard() { importBytes?.fill(0); importBytes = null; importKeyFile?.fill(0); importKeyFile = null }
            AlertDialog(onDismissRequest = {}, icon = { Icon(Icons.Outlined.EnhancedEncryption, null) }, title = { Text(stringResource(when { transfer -> R.string.transfer_import_title; keepass -> R.string.import_kdbx_title; keeper -> R.string.main_keeper_backup_title; else -> R.string.main_encrypted_backup_title })) },
                text = { HardenWindow(); Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(when { transfer -> R.string.transfer_import_body; keepass -> R.string.import_kdbx_body; keeper -> R.string.main_keeper_backup_body; else -> R.string.main_encrypted_backup_body }))
                    // The transfer code is read off another screen, so it is typed in the clear, with the dashes the other phone shows added for the user.
                    if (transfer) OutlinedTextField(backupPassword, { backupPassword = Transfer.typing(it) }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.transfer_code_label)) }, singleLine = true, shape = RoundedCornerShape(12.dp),
                        visualTransformation = TransferCodeTransformation, keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Characters, keyboardType = KeyboardType.Ascii), textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace))
                    else SecretInput(stringResource(R.string.main_backup_password), backupPassword, { backupPassword = it })
                    if (keepass) {
                        if (importKeyFile == null) OutlinedButton(onClick = { launchPicker { keyFilePicker.launch(arrayOf("*/*")) } }, Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Key, null); Text("  " + stringResource(R.string.import_keyfile_choose)) }
                        else Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.Key, null, tint = MaterialTheme.colorScheme.primary); Text(stringResource(R.string.import_keyfile_chosen), Modifier.weight(1f).padding(start = 8.dp))
                            IconButton(onClick = { importKeyFile?.fill(0); importKeyFile = null }) { Icon(Icons.Default.Close, stringResource(R.string.import_keyfile_remove)) }
                        }
                    }
                } },
                // A KeePass database may have an empty password, or only a key file.
                confirmButton = { TextButton(onClick = { val bytes = importBytes ?: return@TextButton; val pass = backupPassword; val key = importKeyFile; backupPassword = ""
                    readImport({ when { Transfer.isTransfer(bytes) -> Transfer.open(bytes, pass); Kdbx.isKdbx(bytes) -> Kdbx.importTyped(bytes, pass, key); Pkb2.isPkb2(bytes) -> Pkb2.import(bytes, pass); else -> VaultCrypto.importBackup(bytes, pass) } }) { bytes.fill(0); key?.fill(0); if (importBytes === bytes) { importBytes = null; importKeyFile = null } } },
                    enabled = backupPassword.isNotEmpty() || keepass) { Text(stringResource(R.string.main_decrypt)) } },
                dismissButton = { TextButton(onClick = { discard() }) { Text(stringResource(R.string.main_cancel)) } })
        }
        importPreview?.let { imported -> AlertDialog(onDismissRequest = { importPreview = null }, icon = { Icon(Icons.Outlined.FileOpen, null) }, title = { Text(stringResource(R.string.main_import_title, imported.size)) }, text = { HardenWindow(); val seeds = imported.count { it.type == RecordType.seed }; Text(when { seeds == 0 -> stringResource(R.string.main_import_body); seeds == 1 -> stringResource(R.string.main_import_body_seed_one, seeds); else -> stringResource(R.string.main_import_body_seed_many, seeds) }) }, confirmButton = { Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                fun start(replace: Boolean) { importPreview = null; work({ if (replace) engine.replaceAll(imported) else engine.merge(imported) }) { settings = false; message = getString(R.string.main_imported_count, imported.size) } }
                TextButton(onClick = { importPreview = null }, Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 4.dp)) { Text(stringResource(R.string.main_cancel), textAlign = TextAlign.Center) }
                TextButton(onClick = { start(true) }, Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 4.dp), colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(stringResource(R.string.main_import_replace_all), textAlign = TextAlign.Center) }
                TextButton(onClick = { start(false) }, Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 4.dp), colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.primary)) { Text(stringResource(R.string.main_import_action), textAlign = TextAlign.Center) }
            } }) }
    }
    @Composable private fun FileDialogs() {
        fileProgress?.let { FileProgressDialog(it) { fileJob?.cancel() } }
        encryptedOriginal?.let { (original, saved) ->
            AlertDialog(onDismissRequest = { encryptedOriginal = null }, icon = { Icon(Icons.Outlined.Lock, null) }, title = { Text(stringResource(R.string.files_encrypted_title)) },
                text = { HardenWindow(); Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.files_encrypted_body, saved))
                    if (FileKeys.needsBackup(fileKeys, lastBackup, backedUpKeys)) Text(stringResource(R.string.files_encrypted_backup_warning), color = MaterialTheme.colorScheme.error)
                } },
                confirmButton = { TextButton(onClick = { encryptedOriginal = null
                    val epoch = generation; val source = fileVault()
                    lifecycleScope.launch {
                        val deleted = fileJobs.withOutput { withContext(Dispatchers.IO) {
                            FileCrypt.delete(contentResolver, original.uri).also { if (!it) fileNotices.add(source, getString(R.string.files_original_not_deleted)) }
                        } }
                        if (deleted && epoch == generation && unlocked) message = getString(R.string.files_original_deleted)
                    } }) {
                    Text(stringResource(R.string.files_delete_original), color = MaterialTheme.colorScheme.error) } },
                dismissButton = { TextButton(onClick = { encryptedOriginal = null }) { Text(stringResource(R.string.files_keep_original)) } })
        }
    }
    /** Opens one of the app's own system pickers under the picker auto-lock grace period; false (with a message) when none is available. */
    private fun launchPicker(launch: () -> Unit): Boolean {
        systemPickerOpen = true
        return try { launch(); true } catch (e: android.content.ActivityNotFoundException) { systemPickerOpen = false; messageError = true; message = getString(R.string.main_cannot_open_file); false }
    }
    /** e.g. passvault_2026-09-29_10_31.pvault, in local time. */
    private fun exportFileName(extension: String) = "passvault_" + java.time.LocalDateTime.now().format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd_HH_mm")) + "." + extension
    private fun prepareExport(password: String, csv: Boolean) {
        if (!ready || busy) return
        busy = true; message = ""; messageError = false; val epoch = generation
        lifecycleScope.launch {
            // Keep ownership even if cancellation drops withContext's result on its way back to the main thread.
            var prepared: VaultExport? = null
            try {
                // Off the vault queue: the estimate loads zxcvbn's dictionaries on first use, and nothing else should wait for that.
                val weak = withContext(Dispatchers.Default) { VaultEngine.weakBackupPassword(password, csv) }
                val attemptsRemaining = withContext(vaultQueue) { prepared = engine.export(password, csv, weak) { decoy -> BackupStatus(prefs, if (decoy) "decoy." else "").instance }; engine.remainingAttempts() }
                if (epoch != generation || !unlocked) { refreshUnlockScreen(); return@launch }
                remaining = attemptsRemaining
                val snapshot = checkNotNull(prepared)
                discardPendingExport(); pendingExport = snapshot; prepared = null
                if (!launchPicker { if (snapshot.csv) csvExport.launch(exportFileName("csv")) else encryptedExport.launch(exportFileName("pvault")) }) discardPendingExport()
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            // After a lock, a wrong password still counted (and may have erased the vault): the unlock screen must show it.
            catch (e: Exception) { if (epoch == generation) reportWorkError(e) else refreshUnlockScreen() }
            finally { prepared?.clear(); busy = false }
        }
    }
    private fun exportError(e: Exception) = when (e) {
        is FileCrypt.LeftBehind -> getString(R.string.main_export_left_behind)
        is FileCrypt.UnsafeTarget -> getString(R.string.files_new_target)
        else -> e.message ?: getString(R.string.main_export_failed)
    }
    private fun writeExport(uri: android.net.Uri?) {
        systemPickerOpen = false
        // Locked while the picker was open: the export is gone, so remove the empty file the picker created.
        val snapshot = pendingExport ?: run { uri?.let(::discardUnwritten); return }; pendingExport = null
        val epoch = generation
        lifecycleScope.launch {
            try {
                if (uri != null) writeWholeFile(uri, snapshot.bytes, FileVault(snapshot.decoy, snapshot.instance), plaintext = snapshot.csv)
                // Only a saved encrypted backup counts: CSV leaves out 2FA keys, seed phrases, cards and notes.
                if (uri != null) snapshot.recordBackup(prefs, Instant.now())
                if (epoch == generation && unlocked) {
                    loadBackupStatus()
                    messageError = uri != null && snapshot.weakPassword
                    message = if (uri == null) getString(R.string.main_export_cancelled) else if (snapshot.csv) getString(R.string.main_export_csv_done) else if (snapshot.weakPassword) getString(R.string.main_export_encrypted_done_weak) else getString(R.string.main_export_encrypted_done)
                }
            } catch (e: kotlinx.coroutines.CancellationException) { uri?.let(::discardUnwritten); throw e }
            catch (_: FileCrypt.LeftBehind) { /* Queued by the worker. */ }
            catch (e: Exception) { if (epoch == generation && unlocked) { messageError = true; message = exportError(e) } }
            finally { snapshot.clear() }
        }
    }
    /** "today", "yesterday" or "12 days ago". */
    @Composable private fun backupAge(at: Instant): String {
        val days = java.time.Duration.between(at, Instant.now()).toDays().coerceAtLeast(0)
        return when (days) { 0L -> stringResource(R.string.backup_today); 1L -> stringResource(R.string.backup_yesterday); else -> stringResource(R.string.backup_days_ago, days.toInt()) }
    }
    /** The vault keys on the normalized password, so two spellings that normalize alike are the same password. */
    private fun samePassword(a: String, b: String) = PasswordText.normalize(a) == PasswordText.normalize(b)
    /**
     * [PasswordPolicy.problem] for a new password, worked out off the main thread (the guessability estimate loads dictionaries on first
     * use); [PASSWORD_CHECKING] until it is known, so a button never enables on a password that has not been checked yet.
     */
    @Composable private fun passwordProblem(value: String): Int? {
        // Keyed on the text, so new text reads as checking in the very composition it appears in (produceState would keep the previous
        // text's result until its coroutine starts, enabling a button for one frame).
        val result = remember(value) { mutableStateOf<Int?>(PASSWORD_CHECKING) }
        LaunchedEffect(value) {
            // The estimate itself cannot be cancelled: wait for a pause in typing, so each keystroke does not start another.
            kotlinx.coroutines.delay(150)
            result.value = withContext(Dispatchers.Default) { PasswordPolicy.problem(value) }
        }
        return result.value
    }
    /** [checked]: [passwordProblem] of [value], worked out once by the caller, which also uses it to enable its button. */
    @Composable private fun PasswordHint(value: String, checked: Int?) {
        val problem = if (value.isEmpty() || checked == PASSWORD_CHECKING) null else checked
        Text(stringResource(problem ?: if (value.isEmpty() || checked == PASSWORD_CHECKING) PasswordPolicy.RULE else R.string.main_password_meets), Modifier.fillMaxWidth().padding(top = 8.dp), style = MaterialTheme.typography.bodySmall, color = if (problem != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
    }
    @Composable private fun SecretInput(label: String, value: String, change: (String) -> Unit) {
        var visible by remember { mutableStateOf(false) }
        OutlinedTextField(value, change, Modifier.fillMaxWidth(), label = { Text(label) }, visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password), singleLine = true, shape = RoundedCornerShape(12.dp),
            trailingIcon = { IconButton(onClick = { visible = !visible }) { Icon(if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (visible) stringResource(R.string.main_hide_password) else stringResource(R.string.main_show_password)) } })
    }
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { systemPickerOpen = false }
    // The countdown notification is optional (clearing works without it), so ask only once.
    private fun askNotificationsOnce() {
        if (android.os.Build.VERSION.SDK_INT < 33 || prefs.getBoolean("askedNotifications", false)) return
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED) return
        prefs.edit().putBoolean("askedNotifications", true).apply()
        systemPickerOpen = true; notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
    }
    /** Asks Android to make PassVault the autofill service (the system shows its own confirmation), or stops being it. */
    private fun setAutofill(on: Boolean) {
        if (!on) { runCatching { autofillManager?.disableAutofillServices() }; autofillEnabled = autofillManager?.hasEnabledAutofillServices() == true; return }
        launchPicker { autofillSetup.launch(Intent(android.provider.Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE, android.net.Uri.parse("package:$packageName"))) }
    }
    private fun updateAllowCopy(on: Boolean) { allowCopy = on; prefs.edit().putBoolean("allowCopy", on).apply(); if (!on) clearCopiedText() }
    private fun updateClearOnLock(on: Boolean) { clearClipOnLock = on; prefs.edit().putBoolean("clearClipOnLock", on).apply() }
    private fun copySecret(value: String) {
        if (!allowCopy) return
        val clipboard = getSystemService(android.content.ClipboardManager::class.java)
        val token = "passvault-" + java.util.UUID.randomUUID()
        val clip = android.content.ClipData.newPlainText(token, value)
        clip.description.extras = android.os.PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
        clipboard.setPrimaryClip(clip); clipToken = token
        val delay = clipboardClear.millis
        if (delay != null) runCatching { ClipboardClearService.schedule(this, delay, clearClipOnLock) }.onFailure { messageError = true; message = getString(R.string.main_clipboard_schedule_failed, it.message.orEmpty()); return }
        else ClipboardClearService.cancel(this)
        askNotificationsOnce()
        message = if (delay == null) getString(R.string.main_copied) else getString(R.string.main_copied_clears_in, getString(clipboardClear.labelRes))
    }
    // Android hides clipboard contents from background apps, so when we cannot see the current clip we
    // assume it is still ours and clear it. When we can see it and it belongs to someone else, leave it.
    private fun clearCopiedText() {
        clipToken ?: return
        ClipboardClearService.cancel(this)
        val clipboard = getSystemService(android.content.ClipboardManager::class.java)
        val label = runCatching { clipboard.primaryClipDescription?.label?.toString() }.getOrNull()
        if (label == null || label == clipToken) ClipboardClearService.wipe(this)
        clipToken = null
    }
}
