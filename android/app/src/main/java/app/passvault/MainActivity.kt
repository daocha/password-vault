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
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
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
    data class Exporting(val kind: Export) : SettingsDialog
}

private val LANGUAGES = listOf("", "en", "zh-Hans", "zh-Hant")
private fun languageName(tag: String) = when (tag) { "en" -> R.string.main_language_english; "zh-Hans" -> R.string.main_language_zh_hans; "zh-Hant" -> R.string.main_language_zh_hant; else -> R.string.main_language_system }

class MainActivity : FragmentActivity() {
    private companion object { const val PICKER_GRACE_MILLIS = 120_000L }
    private lateinit var engine: VaultEngine
    // Every engine call runs on this one queue, so a lock can never interleave with the next unlock or save.
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val vaultQueue = Dispatchers.IO.limitedParallelism(1)
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
    override fun attachBaseContext(newBase: Context) {
        val tag = newBase.getSharedPreferences("settings", MODE_PRIVATE).getString("language", "").orEmpty()
        if (tag.isEmpty()) return super.attachBaseContext(newBase)
        val config = android.content.res.Configuration(newBase.resources.configuration).apply { setLocale(java.util.Locale.forLanguageTag(tag)) }
        super.attachBaseContext(newBase.createConfigurationContext(config))
    }
    private var biometricEnabled by mutableStateOf(false)
    private var biometricAutoPrompted = false
    private var enablingBiometric = false
    private var importPreview by mutableStateOf<List<VaultRecord>?>(null)
    private val screenOff = object : BroadcastReceiver() { override fun onReceive(context: Context, intent: Intent) { if (unlocked) lockVault() else discardPendingUnlock() } }
    /** An unlock still deriving its key when the app leaves the foreground must not complete unattended: its result is dropped and the engine re-locked. */
    private fun discardPendingUnlock() { if (busy && !unlocked) generation++ }
    private var generation by mutableIntStateOf(0)
    private var settings by mutableStateOf(false)
    private var seedTab by mutableStateOf(false)
    // List filters live here, not in VaultScreen, so they survive opening an entry and coming back.
    private var query by mutableStateOf("")
    private var favorites by mutableStateOf(false)
    private var group by mutableStateOf<String?>(null)
    private var viewing by mutableStateOf<VaultRecord?>(null)
    private var editing by mutableStateOf(false)
    private var importBytes by mutableStateOf<ByteArray?>(null)
    private var exportBytes: ByteArray? = null
    private var exportIsCSV = false
    private lateinit var biometricPrompt: BiometricPrompt
    // System back walks up one screen (editor → entry → list, settings → list); on the list it leaves the app.
    private val backCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            val record = viewing
            when {
                selected.isNotEmpty() -> selected = emptySet()
                record != null && editing && records.any { it.id == record.id } -> editing = false
                record != null -> { viewing = null; editing = false }
                settings -> settings = false
            }
        }
    }
    private var biometricCandidate: ByteArray? = null

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
                if (VaultCrypto.isBackup(bytes) || Pkb2.isPkb2(bytes)) importBytes = bytes // Password dialog decrypts it.
                else readImport({ try { VaultCSV.importRecords(bytes.toString(Charsets.UTF_8)) } finally { bytes.fill(0) } })
            } catch (e: Exception) { messageError = true; message = e.message ?: getString(R.string.main_import_failed) }
        }
    }
    private fun readImport(parse: () -> List<VaultRecord>, parsed: () -> Unit = {}) {
        if (busy) return
        busy = true; message = ""; messageError = false; val epoch = generation
        lifecycleScope.launch {
            try { val result = withContext(Dispatchers.IO) { parse() }; parsed(); if (epoch == generation && unlocked) { if (result.isEmpty()) message = getString(R.string.main_file_no_records) else importPreview = result } }
            catch (e: AuthenticationFailure) { messageError = true; message = getString(R.string.main_bad_password_or_backup) }
            catch (e: Exception) { messageError = true; message = e.message ?: getString(R.string.main_import_rejected) }
            finally { busy = false }
        }
    }
    private val encryptedExport = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { writeExport(it) }
    private val csvExport = registerForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { writeExport(it) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
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
        biometricPrompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val enable = enablingBiometric; enablingBiometric = false
                val authenticated = result.cryptoObject?.cipher ?: run { message = getString(R.string.main_biometric_no_key); return }
                if (enable) {
                    val candidate = biometricCandidate ?: return
                    biometricCandidate = null
                    work({ try { engine.saveBiometric(authenticated, candidate); null } finally { candidate.fill(0) } }) { biometricEnabled = true; message = getString(R.string.main_biometric_enabled) }
                } else work({ engine.unlockBiometric(authenticated) })
            }
            override fun onAuthenticationError(code: Int, error: CharSequence) {
                enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null
                if (code != BiometricPrompt.ERROR_USER_CANCELED && code != BiometricPrompt.ERROR_NEGATIVE_BUTTON && code != BiometricPrompt.ERROR_CANCELED) message = error.toString()
            }
        })
        onBackPressedDispatcher.addCallback(this, backCallback)
        lifecycleScope.launch { snapshotFlow { unlocked && (viewing != null || settings || selected.isNotEmpty()) }.collect { backCallback.isEnabled = it } }
        ContextCompat.registerReceiver(this, screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED)
        try { engine = VaultEngine(ProtectedStorage(this)); exists = engine.exists(); remaining = engine.remainingAttempts(); biometricEnabled = engine.hasBiometric(); ready = true }
        catch (e: Exception) { message = e.message ?: getString(R.string.main_storage_unavailable); if (::engine.isInitialized) { erased = runCatching { engine.isErased() }.getOrDefault(false); ready = erased } }
        setContent {
            PassVaultTheme(themeMode) { BlockTextCopy(!allowCopy, ::copySecret) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                        key(generation) {
                            val record = viewing
                            when {
                                !unlocked -> UnlockScreen()
                                record != null -> RecordScreen(record, editing)
                                settings -> SettingsScreen()
                                else -> VaultScreen()
                            }
                        }
                        if (unlocked) ImportDialogs()
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
        // Offer biometrics once per lock; cancelling the prompt must not re-trigger it on the next resume.
        if (ready && exists && !unlocked && !busy && !biometricAutoPrompted && biometricEnabled) { biometricAutoPrompted = true; biometrics() }
    }
    override fun onStop() {
        super.onStop()
        backgroundSince = 0; lockTimeout = null
        if (isChangingConfigurations) return
        if (!unlocked) { discardPendingUnlock(); return }
        backgroundSince = SystemClock.elapsedRealtime()
        // The app's own system pickers get a bounded grace period instead of suspending auto-lock, so leaving from inside a picker still locks.
        val timeout = if (systemPickerOpen) PICKER_GRACE_MILLIS else autoLock.millis ?: return // deviceLock: the screen-off receiver locks.
        lockTimeout = timeout
        if (timeout == 0L) lockVault(clearClipboard = false) else { backgroundLock?.cancel(); backgroundLock = lifecycleScope.launch { delay(timeout); lockVault() } }
    }
    private fun lockVault(clearClipboard: Boolean = true) {
        if (clearClipboard && clearClipOnLock && unlocked) clearCopiedText()
        generation++; unlocked = false; records = emptyList(); selected = emptySet(); query = ""; favorites = false; group = null; viewing = null; editing = false; settings = false
        backgroundLock?.cancel(); backgroundLock = null; biometricAutoPrompted = false
        importPreview = null; importBytes?.fill(0); importBytes = null; exportBytes?.fill(0); exportBytes = null
        if (::biometricPrompt.isInitialized) biometricPrompt.cancelAuthentication()
        enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null
        if (::engine.isInitialized) lifecycleScope.launch(vaultQueue) { engine.lock() }
    }
    override fun onDestroy() {
        unregisterReceiver(screenOff); exportBytes?.fill(0); importBytes?.fill(0); biometricCandidate?.fill(0)
        // The auto-lock coroutine dies with this activity, so zero the data key now (off the main thread: the engine may be mid-Argon2).
        if (::engine.isInitialized) { val e = engine; Thread { e.lock() }.start() }
        super.onDestroy()
    }
    private fun work(action: () -> List<VaultRecord>?, done: () -> Unit = {}) {
        if (!ready || busy) return
        busy = true; message = ""; messageError = false; val epoch = generation
        lifecycleScope.launch {
            try {
                val result = withContext(vaultQueue) { action() }
                if (epoch != generation) {
                    withContext(vaultQueue) { engine.lock() }
                    // The action itself completed (e.g. a vault was created or reset), so refresh what the unlock screen shows.
                    exists = runCatching { engine.exists() }.getOrDefault(exists); erased = runCatching { engine.isErased() }.getOrDefault(erased)
                    remaining = runCatching { engine.remainingAttempts() }.getOrDefault(remaining)
                    return@launch
                }
                if (result != null) { records = result; unlocked = true; exists = true }
                remaining = engine.remainingAttempts(); done()
            } catch (e: Exception) {
                if (!runCatching { engine.isUnlocked() }.getOrDefault(false)) lockVault()
                remaining = runCatching { engine.remainingAttempts() }.getOrDefault(0); erased = runCatching { engine.isErased() }.getOrDefault(false)
                if (erased) biometricEnabled = false
                messageError = true
                message = if (e is AuthenticationFailure && !erased) getString(R.string.main_incorrect_password, remaining) else e.message ?: getString(R.string.main_operation_failed)
            }
            finally { busy = false }
        }
    }
    private fun saveRecord(saved: VaultRecord, done: () -> Unit = {}) {
        val updated = if (records.any { it.id == saved.id }) records.map { if (it.id == saved.id) saved else it } else records + saved
        work({ engine.save(updated); updated }, done)
    }
    private fun biometrics(password: String? = null) {
        if (busy || !ready) return
        val enable = password != null
        if (BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) != BiometricManager.BIOMETRIC_SUCCESS) { message = getString(R.string.main_biometric_not_enrolled); return }
        if (!enable && !biometricEnabled) { message = getString(R.string.main_biometric_use_password_first); return }
        work({
            if (enable) biometricCandidate = engine.biometricKey(password!!)
            null
        }) {
            try {
                val cipher = engine.biometricCipher(enable)
                enablingBiometric = enable
                biometricPrompt.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(if (enable) getString(R.string.main_enable_biometric_unlock) else getString(R.string.main_unlock_passvault)).setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG).setNegativeButtonText(getString(R.string.main_use_app_password)).build(), BiometricPrompt.CryptoObject(cipher))
            } catch (e: KeyPermanentlyInvalidatedException) {
                biometricCandidate?.fill(0); biometricCandidate = null
                runCatching { engine.disableBiometric() }; biometricEnabled = false
                message = getString(R.string.main_biometrics_changed)
            } catch (e: Exception) { enablingBiometric = false; biometricCandidate?.fill(0); biometricCandidate = null; message = e.message ?: getString(R.string.main_biometric_key_unavailable) }
        }
    }

    @Composable private fun UnlockScreen() {
        var password by remember { mutableStateOf("") }; var confirm by remember { mutableStateOf("") }; var consent by remember { mutableStateOf(false) }; var reset by remember { mutableStateOf(false) }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Image(painterResource(R.drawable.vault_icon), stringResource(R.string.main_logo_description), Modifier.size(112.dp))
            Spacer(Modifier.height(24.dp)); Text("PassVault", style = MaterialTheme.typography.headlineLarge)
            Text(stringResource(R.string.main_tagline), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (erased) { Text(stringResource(R.string.main_vault_erased), Modifier.padding(top = 16.dp)); TextButton(onClick = { reset = true }) { Text(stringResource(R.string.main_start_new_vault)) } }
            Spacer(Modifier.height(32.dp)); SecretInput(if (exists) stringResource(R.string.main_app_password) else stringResource(R.string.main_new_app_password), password, { password = it })
            if (!exists) {
                Spacer(Modifier.height(8.dp)); SecretInput(stringResource(R.string.main_repeat_password), confirm, { confirm = it })
                PasswordHint(password)
                Text(stringResource(R.string.main_no_password_reset), Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                CheckRow(consent, { consent = it }) { Text(stringResource(R.string.main_consent_erase)) }
            }
            Button(onClick = { val value = password; password = ""; confirm = ""; work({ if (exists) engine.unlock(value) else engine.create(value) }) }, enabled = ready && password.isNotEmpty() && (exists || (password == confirm && consent && PasswordPolicy.problem(password) == null)), modifier = Modifier.fillMaxWidth().padding(top = 16.dp).height(52.dp)) { Text(if (exists) stringResource(R.string.main_unlock_vault) else stringResource(R.string.main_create_vault)) }
            if (exists && biometricEnabled) OutlinedButton(onClick = { biometrics() }, enabled = ready, modifier = Modifier.fillMaxWidth().padding(top = 8.dp).height(52.dp)) { Icon(Icons.Default.Fingerprint, null); Text("  " + stringResource(R.string.main_unlock_with_biometrics)) }
            if (exists) Text(stringResource(R.string.main_attempts_remaining, remaining), Modifier.padding(top = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (reset) AlertDialog(onDismissRequest = { reset = false }, title = { Text(stringResource(R.string.main_new_empty_vault_title)) }, text = { HardenWindow(); Text(stringResource(R.string.main_erased_cannot_recover)) }, confirmButton = { TextButton(onClick = { reset = false; work({ engine.resetErasedVault(); null }) { erased = false; exists = false; remaining = 10; message = getString(R.string.main_create_then_import) } }) { Text(stringResource(R.string.main_create_new_vault)) } }, dismissButton = { TextButton(onClick = { reset = false }) { Text(stringResource(R.string.main_cancel)) } })
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun VaultScreen() {
        var confirmDelete by remember { mutableStateOf(false) }; var grouping by remember { mutableStateOf(false) }
        val selecting = selected.isNotEmpty(); val haptics = LocalHapticFeedback.current
        val type = if (seedTab) RecordType.seed else RecordType.login
        val ofType = records.filter { it.type == type }
        val groups = remember(records) { records.filter { it.type == RecordType.login }.map { it.group.trim() }.filter { it.isNotEmpty() }.distinct().sortedBy { it.lowercase() } }
        // A group filter whose last entry was moved or deleted has no chip left to clear it.
        LaunchedEffect(groups) { if (group != null && group !in groups) group = null }
        val visible = ofType.filter { it.matches(query) && (!favorites || it.favorite) && (group == null || it.group.trim() == group) }.sortedWith(compareBy({ !it.favorite }, { it.name.lowercase() }))
        // Bulk actions apply only to entries the user can see: narrowing the filters drops hidden entries from the selection.
        LaunchedEffect(visible) { val ids = visible.map { it.id }.toSet(); if (!ids.containsAll(selected)) selected = selected intersect ids }
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                if (selecting) TopAppBar(title = { Text(stringResource(R.string.main_selected_count, selected.size)) }, navigationIcon = { IconButton(onClick = { selected = emptySet() }) { Icon(Icons.Default.Close, stringResource(R.string.main_cancel_selection)) } },
                    actions = {
                        IconButton(onClick = { val ids = visible.map { it.id }.toSet(); selected = if (selected.containsAll(ids)) emptySet() else ids }) { Icon(Icons.Outlined.SelectAll, stringResource(R.string.main_select_all)) }
                        if (!seedTab) IconButton(onClick = { grouping = true }) { Icon(Icons.Outlined.Folder, stringResource(R.string.main_change_group_selected)) }
                        IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.Delete, stringResource(R.string.main_delete_selected)) }
                    }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.secondaryContainer))
                else TopAppBar(title = { Text("PassVault") }, actions = { IconButton(onClick = { lockVault() }) { Icon(Icons.Outlined.Lock, stringResource(R.string.main_lock_vault)) }; IconButton(onClick = { settings = true }) { Icon(Icons.Outlined.Settings, stringResource(R.string.main_settings)) } }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
            },
            floatingActionButton = { if (!selecting) ExtendedFloatingActionButton(onClick = { viewing = if (seedTab) VaultRecord(type = RecordType.seed, fields = emptyList()) else VaultRecord(); editing = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text(if (seedTab) stringResource(R.string.main_new_seed_phrase) else stringResource(R.string.main_new_entry)) }) }) { padding ->
            Column(Modifier.padding(padding).padding(horizontal = 16.dp)) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
                    SegmentedButton(!seedTab, { seedTab = false; group = null; selected = emptySet() }, SegmentedButtonDefaults.itemShape(0, 2), icon = { Icon(Icons.Outlined.Key, null, Modifier.size(18.dp)) }) { Text(stringResource(R.string.main_passwords)) }
                    SegmentedButton(seedTab, { seedTab = true; group = null; selected = emptySet() }, SegmentedButtonDefaults.itemShape(1, 2), icon = { Icon(Icons.Outlined.AccountBalanceWallet, null, Modifier.size(18.dp)) }) { Text(stringResource(R.string.main_seed_phrases)) }
                }
                TextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text(stringResource(R.string.main_search)) }, leadingIcon = { Icon(Icons.Default.Search, null) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Default.Close, stringResource(R.string.main_clear_search)) } }, singleLine = true, shape = RoundedCornerShape(28.dp),
                    colors = TextFieldDefaults.colors(focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh, focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh))
                LazyRow(Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item { FilterChip(favorites, { favorites = !favorites }, label = { Text(stringResource(R.string.main_favorites)) }, leadingIcon = { Icon(if (favorites) Icons.Default.Star else Icons.Outlined.StarOutline, null, Modifier.size(18.dp)) }) }
                    if (!seedTab) items(groups) { name -> FilterChip(group == name, { group = if (group == name) null else name }, label = { Text(name) }, leadingIcon = { Icon(Icons.Outlined.Folder, null, Modifier.size(18.dp)) }) }
                }
                if (ofType.isEmpty()) Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    IconBadge(if (seedTab) Icons.Outlined.AccountBalanceWallet else Icons.Outlined.Key, 72.dp); Spacer(Modifier.height(16.dp))
                    Text(if (seedTab) stringResource(R.string.main_no_seed_phrases) else stringResource(R.string.main_peace_of_mind), style = MaterialTheme.typography.titleLarge)
                    Text(if (seedTab) stringResource(R.string.main_empty_seed_body) else stringResource(R.string.main_empty_login_body), Modifier.padding(top = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                } else Text(stringResource(if (seedTab) R.string.main_count_of_seeds else R.string.main_count_of_entries, visible.size, ofType.size), Modifier.padding(start = 4.dp, bottom = 8.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 96.dp)) {
                    items(visible, key = { it.id }) { record ->
                        val subtitle = if (record.type == RecordType.seed) (if (record.privateKey != null) stringResource(R.string.main_private_key) else stringResource(R.string.main_word_count, record.seedWords.size)) else record.fields.firstOrNull { it.kind == FieldKind.username && it.value.isNotBlank() }?.value ?: record.website.ifBlank { record.group }
                        val isSelected = record.id in selected
                        fun toggle() { selected = if (isSelected) selected - record.id else selected + record.id }
                        Card(modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = if (isSelected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLow)) {
                            Row(Modifier.clickable { if (selecting) toggle() else { viewing = record; editing = false } }.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                // Tapping the icon selects; tapping anywhere else opens the entry (or toggles it while selecting).
                                Box(Modifier.size(44.dp).clip(CircleShape).clickable(onClickLabel = if (isSelected) stringResource(R.string.main_deselect) else stringResource(R.string.main_select)) { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); toggle() }, contentAlignment = Alignment.Center) {
                                    when {
                                        selecting -> Icon(if (isSelected) Icons.Default.CheckCircle else Icons.Outlined.Circle, if (isSelected) stringResource(R.string.main_selected) else stringResource(R.string.main_not_selected), Modifier.size(28.dp), tint = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
                                        record.type == RecordType.seed -> IconBadge(Icons.Outlined.AccountBalanceWallet, 44.dp, MaterialTheme.colorScheme.tertiaryContainer, MaterialTheme.colorScheme.onTertiaryContainer)
                                        else -> RecordAvatar(record.name)
                                    }
                                }
                                Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                                    Text(record.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                if (record.favorite) Icon(Icons.Default.Star, stringResource(R.string.main_favorite), Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                                if (!selecting) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
        if (grouping) GroupDialog { grouping = false }
        if (confirmDelete) {
            val doomed = records.filter { it.id in selected }; val seeds = doomed.count { it.type == RecordType.seed }
            AlertDialog(onDismissRequest = { confirmDelete = false }, icon = { Icon(Icons.Outlined.Delete, null) }, title = { Text(if (doomed.size == 1) stringResource(R.string.main_delete_title_one, doomed.size) else stringResource(R.string.main_delete_title_many, doomed.size)) },
                text = { HardenWindow(); Text(when { seeds == 0 -> stringResource(R.string.main_delete_body); seeds == 1 -> stringResource(R.string.main_delete_body_seed_one, seeds); else -> stringResource(R.string.main_delete_body_seed_many, seeds) }) },
                confirmButton = { TextButton(onClick = { confirmDelete = false; val ids = doomed.map { it.id }.toSet(); val updated = records.filter { it.id !in ids }; work({ engine.save(updated); updated }) { selected = emptySet(); message = if (ids.size == 1) getString(R.string.main_deleted_one, ids.size) else getString(R.string.main_deleted_many, ids.size) } }) { Text(stringResource(R.string.main_delete), color = MaterialTheme.colorScheme.error) } },
                dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.main_cancel)) } })
        }
    }

    /** Assigns the selected entries to a group. Each row shows whether all (ticked), some (solid) or none (empty) of them are in that group; tapping assigns or clears them all. */
    @Composable private fun GroupDialog(dismiss: () -> Unit) {
        val targets = remember { records.filter { it.id in selected && it.type == RecordType.login } }
        var pending by remember { mutableStateOf(targets.associate { it.id to it.group.trim() }) }
        val allGroups = remember { records.filter { it.type == RecordType.login }.map { it.group.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() } }
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
                work({ engine.save(updated); updated }) { selected = emptySet(); message = if (updates.size == 1) getString(R.string.main_updated_group_one, updates.size) else getString(R.string.main_updated_group_many, updates.size) }
            }) { Text(stringResource(R.string.main_apply)) } },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.main_cancel)) } })
    }
    @Composable private fun RecordScreen(record: VaultRecord, edit: Boolean) {
        if (record.type == RecordType.seed) {
            val isNew = records.none { it.id == record.id }
            if (edit) SeedEditor(record, isNew, onCancel = { if (isNew) viewing = null else editing = false }, onSave = { saved -> saveRecord(saved) { viewing = saved; editing = false } })
            else SeedDetail(record, onBack = { viewing = null }, onEdit = { editing = true },
                onDelete = { val updated = records.filter { it.id != record.id }; work({ engine.save(updated); updated }) { viewing = null } },
                onToggleFavorite = { val saved = record.copy(favorite = !record.favorite); saveRecord(saved) { viewing = saved } })
        } else if (edit) RecordEditor(record) else RecordDetail(record)
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun RecordDetail(record: VaultRecord) {
        var revealed by remember(record.id) { mutableStateOf(emptySet<String>()) }; var menu by remember { mutableStateOf(false) }; var deleting by remember { mutableStateOf(false) }; var historyFor by remember(record.id) { mutableStateOf<String?>(null) }
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            topBar = { TopAppBar(title = {}, navigationIcon = { IconButton(onClick = { viewing = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.main_back)) } },
                actions = {
                    IconButton(onClick = { val saved = record.copy(favorite = !record.favorite); saveRecord(saved) { viewing = saved } }) { Icon(if (record.favorite) Icons.Default.Star else Icons.Outlined.StarOutline, if (record.favorite) stringResource(R.string.main_remove_favorite) else stringResource(R.string.main_add_favorite), tint = if (record.favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                    IconButton(onClick = { editing = true }) { Icon(Icons.Outlined.Edit, stringResource(R.string.main_edit)) }
                    Box { IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, stringResource(R.string.main_more)) }
                        DropdownMenu(menu, { menu = false }) { DropdownMenuItem(text = { Text(stringResource(R.string.main_delete_entry)) }, leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = { menu = false; deleting = true }) } }
                }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
            LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                item {
                    Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        RecordAvatar(record.name, 72.dp)
                        Text(record.name, Modifier.padding(top = 12.dp), style = MaterialTheme.typography.headlineSmall)
                        if (record.website.isNotBlank()) Text(record.website, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                        if (record.group.isNotBlank()) AssistChip(onClick = {}, label = { Text(record.group) }, leadingIcon = { Icon(Icons.Outlined.Folder, null, Modifier.size(18.dp)) }, modifier = Modifier.padding(top = 8.dp))
                    }
                }
                item {
                    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                        if (record.fields.isEmpty()) Text(stringResource(R.string.main_no_fields), Modifier.padding(20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        record.fields.forEachIndexed { index, field ->
                            if (index > 0) HorizontalDivider(Modifier.padding(start = 72.dp), color = MaterialTheme.colorScheme.outlineVariant)
                            val shown = !field.secret || field.id in revealed
                            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                IconBadge(field.kind.icon)
                                Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                                    Text(field.displayName, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    if (field.kind == FieldKind.question && field.question.isNotBlank()) Text(field.question, style = MaterialTheme.typography.bodyMedium)
                                    when {
                                        field.value.isEmpty() -> Text("—", color = MaterialTheme.colorScheme.outline)
                                        shown -> Text(field.value, style = MaterialTheme.typography.bodyLarge, fontFamily = if (field.kind == FieldKind.password) FontFamily.Monospace else null)
                                        else -> Text("••••••••••", style = MaterialTheme.typography.bodyLarge)
                                    }
                                }
                                if (field.secret && field.value.isNotEmpty()) IconButton(onClick = { revealed = if (field.id in revealed) revealed - field.id else revealed + field.id }) { Icon(if (field.id in revealed) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (field.id in revealed) stringResource(R.string.main_hide) else stringResource(R.string.main_reveal)) }
                                if (field.history.isNotEmpty()) IconButton(onClick = { historyFor = field.id }) { Icon(Icons.Outlined.History, stringResource(R.string.main_password_history_for, field.displayName)) }
                                if (allowCopy && field.value.isNotEmpty()) IconButton(onClick = { copySecret(field.value) }) { Icon(Icons.Outlined.ContentCopy, stringResource(R.string.main_copy_field, field.displayName)) }
                            }
                        }
                    }
                }
                formatUpdated(record.updatedAt)?.let { item { Text(stringResource(R.string.main_updated_at, it), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center) } }
            }
        }
        record.fields.firstOrNull { it.id == historyFor }?.let { field -> PasswordHistorySheet(field) { historyFor = null } }
        if (deleting) AlertDialog(onDismissRequest = { deleting = false }, icon = { Icon(Icons.Outlined.Delete, null) }, title = { Text(stringResource(R.string.main_delete_this_entry)) }, text = { HardenWindow(); Text(stringResource(R.string.main_delete_this_entry_body, record.name)) },
            confirmButton = { TextButton(onClick = { deleting = false; val updated = records.filter { it.id != record.id }; work({ engine.save(updated); updated }) { viewing = null } }) { Text(stringResource(R.string.main_delete)) } },
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
            topBar = { TopAppBar(title = { Text(if (isNew) stringResource(R.string.main_new_entry) else stringResource(R.string.main_edit_entry)) }, navigationIcon = { IconButton(onClick = { cancel() }) { Icon(Icons.Default.Close, stringResource(R.string.main_discard_changes)) } },
                actions = {
                    IconButton(onClick = { record = record.copy(favorite = !record.favorite) }) { Icon(if (record.favorite) Icons.Default.Star else Icons.Outlined.StarOutline, if (record.favorite) stringResource(R.string.main_remove_favorite) else stringResource(R.string.main_add_favorite), tint = if (record.favorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                    Button(onClick = { val saved = record.copy(name = record.name.trim(), updatedAt = Instant.now().toString()).recordingPasswordChanges(records.firstOrNull { it.id == record.id }); saveRecord(saved) { viewing = saved; editing = false } }, enabled = record.name.isNotBlank(), modifier = Modifier.padding(end = 8.dp)) { Text(stringResource(R.string.main_save)) }
                }, colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
            LazyColumn(Modifier.padding(padding), state = listState, contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item(key = "details") {
                    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            EditorField(record.name, { record = record.copy(name = it) }, stringResource(R.string.main_name), Icons.Outlined.Badge)
                            EditorField(record.website, { record = record.copy(website = it) }, stringResource(R.string.main_website), Icons.Outlined.Language, KeyboardType.Uri)
                            GroupField(record.group) { record = record.copy(group = it) }
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
                            Box(Modifier.padding(top = 8.dp)) { IconBadge(field.kind.icon, 36.dp) }
                            Column(Modifier.weight(1f).padding(start = 12.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(field.displayName, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    IconButton(onClick = { record = record.copy(fields = record.fields.filter { it.id != field.id }) }, modifier = Modifier.size(36.dp)) { Icon(Icons.Outlined.RemoveCircleOutline, stringResource(R.string.main_remove_field, field.displayName), Modifier.size(20.dp), tint = MaterialTheme.colorScheme.error) }
                                }
                                if (field.kind == FieldKind.question) { EditorField(field.question, { update(field.copy(question = it)) }, stringResource(R.string.main_question)); Spacer(Modifier.height(8.dp)) }
                                val hidden = field.secret && field.id !in revealed
                                OutlinedTextField(field.value, { update(field.copy(value = it)) }, Modifier.fillMaxWidth(), placeholder = { Text(if (field.kind == FieldKind.question) stringResource(R.string.main_answer) else field.displayName) },
                                    singleLine = field.kind != FieldKind.note, shape = RoundedCornerShape(12.dp), textStyle = if (field.kind == FieldKind.password && !hidden) LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace) else LocalTextStyle.current,
                                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = if (field.secret) KeyboardType.Password else KeyboardType.Text),
                                    visualTransformation = if (hidden) PasswordVisualTransformation() else VisualTransformation.None,
                                    trailingIcon = { if (field.secret) Row {
                                        if (field.kind == FieldKind.password) IconButton(onClick = { generatingFor = field.id }) { Icon(Icons.Outlined.AutoAwesome, stringResource(R.string.main_generate_password)) }
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
        val groups = remember(records) { records.filter { it.type == RecordType.login }.map { it.group.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() }.sortedBy { it.lowercase() } }
        var expanded by remember { mutableStateOf(false) }
        val typed = value.trim()
        val options = if (typed.isEmpty()) groups else groups.filter { it.contains(typed, ignoreCase = true) && !it.equals(typed, ignoreCase = true) }
        ExposedDropdownMenuBox(expanded && options.isNotEmpty(), { expanded = it }) {
            OutlinedTextField(value, { change(it); expanded = true }, Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryEditable), label = { Text(stringResource(R.string.main_group)) }, leadingIcon = { Icon(Icons.Outlined.Folder, null) },
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
        var dialog by remember { mutableStateOf<SettingsDialog?>(null) }
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
                    Row(Icons.Outlined.Timer, stringResource(R.string.main_auto_lock), stringResource(autoLock.labelRes)) { dialog = SettingsDialog.AutoLockChoice }
                    Row(Icons.Outlined.Fingerprint, stringResource(R.string.main_biometric_unlock), if (biometricEnabled) stringResource(R.string.main_on) else stringResource(R.string.main_off), trailing = { Switch(biometricEnabled, { on -> if (on) dialog = SettingsDialog.EnableBiometrics else { runCatching { engine.disableBiometric() }; biometricEnabled = false; message = getString(R.string.main_biometric_turned_off) } }) }) {
                        if (biometricEnabled) { runCatching { engine.disableBiometric() }; biometricEnabled = false; message = getString(R.string.main_biometric_turned_off) } else dialog = SettingsDialog.EnableBiometrics
                    }
                    Row(Icons.Outlined.Password, stringResource(R.string.main_change_app_password)) { dialog = SettingsDialog.ChangePassword }
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
                    Row(Icons.Outlined.FileOpen, stringResource(R.string.main_import_action), stringResource(R.string.main_import_row_summary)) { launchPicker { importPicker.launch(arrayOf("*/*")) } }
                    Row(Icons.Outlined.EnhancedEncryption, stringResource(R.string.main_export_encrypted), stringResource(R.string.main_export_encrypted_summary)) { dialog = SettingsDialog.Exporting(Export.encrypted) }
                    Row(Icons.Outlined.Description, stringResource(R.string.main_export_csv), stringResource(R.string.main_export_csv_summary)) { dialog = SettingsDialog.Exporting(Export.csv) }
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
                    exportIsCSV = csv
                    work({ exportBytes?.fill(0); exportBytes = engine.export(pass, csv); null }) { if (!launchPicker { if (csv) csvExport.launch(exportFileName("csv")) else encryptedExport.launch(exportFileName("pvault")) }) { exportBytes?.fill(0); exportBytes = null } }
                }
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
        AlertDialog(onDismissRequest = dismiss, icon = { Icon(Icons.Outlined.Password, null) }, title = { Text(stringResource(R.string.main_change_app_password)) },
            text = { HardenWindow(); Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SecretInput(stringResource(R.string.main_current_password), current, { current = it }); SecretInput(stringResource(R.string.main_new_password), next, { next = it }); SecretInput(stringResource(R.string.main_repeat_new_password), repeat, { repeat = it })
                PasswordHint(next)
                if (repeat.isNotEmpty() && repeat != next) Text(stringResource(R.string.main_passwords_dont_match), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                Text(stringResource(R.string.main_existing_backups_keep), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } },
            confirmButton = { TextButton(onClick = { val c = current; val n = next; current = ""; next = ""; repeat = ""; dismiss(); work({ engine.changePassword(c, n); null }) { message = getString(R.string.main_app_password_changed) } }, enabled = current.isNotEmpty() && PasswordPolicy.problem(next) == null && next == repeat) { Text(stringResource(R.string.main_change)) } },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.main_cancel)) } })
    }
    @Composable private fun ImportDialogs() {
        if (importBytes != null) {
            var backupPassword by remember { mutableStateOf("") }
            val keeper = importBytes?.let { Pkb2.isPkb2(it) } == true
            AlertDialog(onDismissRequest = {}, icon = { Icon(Icons.Outlined.EnhancedEncryption, null) }, title = { Text(if (keeper) stringResource(R.string.main_keeper_backup_title) else stringResource(R.string.main_encrypted_backup_title)) },
                text = { HardenWindow(); Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { Text(if (keeper) stringResource(R.string.main_keeper_backup_body) else stringResource(R.string.main_encrypted_backup_body)); SecretInput(stringResource(R.string.main_backup_password), backupPassword, { backupPassword = it }) } },
                confirmButton = { TextButton(onClick = { val bytes = importBytes ?: return@TextButton; val pass = backupPassword; backupPassword = ""; readImport({ if (Pkb2.isPkb2(bytes)) Pkb2.import(bytes, pass) else VaultCrypto.importBackup(bytes, pass) }) { bytes.fill(0); if (importBytes === bytes) importBytes = null } }, enabled = backupPassword.isNotEmpty()) { Text(stringResource(R.string.main_decrypt)) } },
                dismissButton = { TextButton(onClick = { importBytes?.fill(0); importBytes = null }) { Text(stringResource(R.string.main_cancel)) } })
        }
        importPreview?.let { imported -> AlertDialog(onDismissRequest = { importPreview = null }, icon = { Icon(Icons.Outlined.FileOpen, null) }, title = { Text(stringResource(R.string.main_import_title, imported.size)) }, text = { HardenWindow(); val seeds = imported.count { it.type == RecordType.seed }; Text(when { seeds == 0 -> stringResource(R.string.main_import_body); seeds == 1 -> stringResource(R.string.main_import_body_seed_one, seeds); else -> stringResource(R.string.main_import_body_seed_many, seeds) }) }, confirmButton = { TextButton(onClick = { importPreview = null; work({ engine.merge(imported) }) { settings = false; message = getString(R.string.main_imported_count, imported.size) } }) { Text(stringResource(R.string.main_import_action)) } }, dismissButton = { TextButton(onClick = { importPreview = null }) { Text(stringResource(R.string.main_cancel)) } }) }
    }
    /** Opens one of the app's own system pickers under the picker auto-lock grace period; false (with a message) when none is available. */
    private fun launchPicker(launch: () -> Unit): Boolean {
        systemPickerOpen = true
        return try { launch(); true } catch (e: android.content.ActivityNotFoundException) { systemPickerOpen = false; messageError = true; message = getString(R.string.main_cannot_open_file); false }
    }
    /** e.g. passvault_2026-09-29_10_31.pvault, in local time. */
    private fun exportFileName(extension: String) = "passvault_" + java.time.LocalDateTime.now().format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd_HH_mm")) + "." + extension
    private fun writeExport(uri: android.net.Uri?) {
        systemPickerOpen = false
        val bytes = exportBytes ?: return; exportBytes = null
        lifecycleScope.launch {
            try { if (uri != null) withContext(Dispatchers.IO) { contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } ?: error(getString(R.string.main_export_could_not_write)) }; message = if (uri == null) getString(R.string.main_export_cancelled) else if (exportIsCSV) getString(R.string.main_export_csv_done) else getString(R.string.main_export_encrypted_done) }
            catch (e: Exception) { message = e.message ?: getString(R.string.main_export_failed) }
            finally { bytes.fill(0) }
        }
    }
    @Composable private fun PasswordHint(value: String) {
        val problem = if (value.isEmpty()) null else PasswordPolicy.problem(value)
        Text(stringResource(problem ?: if (value.isEmpty()) PasswordPolicy.RULE else R.string.main_password_meets), Modifier.fillMaxWidth().padding(top = 8.dp), style = MaterialTheme.typography.bodySmall, color = if (problem != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
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
