package app.passvault

import android.app.assist.AssistStructure
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.view.WindowManager
import android.view.autofill.AutofillManager
import androidx.activity.compose.setContent
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers

/**
 * Opened by a PassVault suggestion in another app: unlocks the vault (app password or biometrics), shows the logins for that app or site
 * first, and fills the one the user picks. The vault is open only while this screen is: leaving it, turning the screen off or filling locks it.
 */
class AutofillActivity : FragmentActivity() {
    private lateinit var engine: VaultEngine
    private lateinit var form: AutofillForm
    private lateinit var targetName: String
    /** The open vault's logins; null while locked. */
    private var records by mutableStateOf<List<VaultRecord>?>(null)
    private var busy by mutableStateOf(false)
    private var ready by mutableStateOf(false)
    private var message by mutableStateOf("")
    private var remaining by mutableIntStateOf(10)
    private var biometricEnabled by mutableStateOf(false)
    private var biometricAutoPrompted = false
    private lateinit var biometricPrompt: BiometricPrompt
    private val screenOff = object : BroadcastReceiver() { override fun onReceive(context: Context, intent: Intent) { finish() } }

    override fun attachBaseContext(newBase: Context) = super.attachBaseContext(withAppLanguage(newBase))

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The same window protection as the app itself (see MainActivity).
        if (BuildConfig.BUILD_TYPE != "debug") window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        window.decorView.importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        window.decorView.importantForContentCapture = android.view.View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
        if (android.os.Build.VERSION.SDK_INT >= 31) window.setHideOverlayWindows(true)
        window.decorView.filterTouchesWhenObscured = true
        setResult(RESULT_CANCELED)
        @Suppress("DEPRECATION")
        val structure = if (android.os.Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE, AssistStructure::class.java) else intent.getParcelableExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE)
        form = structure?.let(AutofillForm::parse) ?: return finish()
        val appName = PassVaultAutofillService.appLabel(this, form.target.packageName)
        targetName = form.target.description(appName)
        lifecycleScope.launch {
            try {
                val status = withContext(vaultQueue) {
                    engine = VaultEngine(ProtectedStorage(this@AutofillActivity))
                    engine.remainingAttempts() to engine.hasBiometric()
                }
                remaining = status.first; biometricEnabled = status.second; ready = true
                if (lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)) autoBiometrics()
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) { message = e.message ?: getString(R.string.main_storage_unavailable) }
        }
        biometricPrompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (isFinishing || !lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) return
                val cipher = result.cryptoObject?.cipher ?: run { message = getString(R.string.main_biometric_no_key); return }
                unlock { engine.unlockBiometric(cipher) }
            }
            override fun onAuthenticationError(code: Int, error: CharSequence) {
                if (code != BiometricPrompt.ERROR_USER_CANCELED && code != BiometricPrompt.ERROR_NEGATIVE_BUTTON && code != BiometricPrompt.ERROR_CANCELED) message = error.toString()
            }
        })
        ContextCompat.registerReceiver(this, screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED)
        val theme = runCatching { ThemeMode.valueOf(getSharedPreferences("settings", MODE_PRIVATE).getString("theme", null) ?: "") }.getOrDefault(ThemeMode.system)
        setContent {
            PassVaultTheme(theme) { BlockTextCopy(block = true) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
                        val open = records
                        if (open == null) UnlockScreen() else PickScreen(open)
                        if (busy) Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background.copy(alpha = .92f)) { Box(contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
                        if (message.isNotEmpty()) Snackbar(Modifier.align(Alignment.TopCenter).padding(16.dp), containerColor = MaterialTheme.colorScheme.errorContainer, contentColor = MaterialTheme.colorScheme.onErrorContainer,
                            dismissAction = { TextButton(onClick = { message = "" }) { Text(stringResource(R.string.main_ok), color = MaterialTheme.colorScheme.onErrorContainer) } }) {
                            Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Default.Warning, null, Modifier.padding(end = 12.dp)); Text(message) }
                        }
                    }
                }
            } }
        }
    }
    override fun onResume() {
        super.onResume()
        autoBiometrics()
    }
    private fun autoBiometrics() {
        if (ready && records == null && !busy && !biometricAutoPrompted && biometricEnabled) { biometricAutoPrompted = true; biometrics() }
    }
    // Leaving this screen ends it: the other app gets nothing, and the vault locks in onDestroy.
    override fun onStop() { super.onStop(); if (!isChangingConfigurations) finish() }
    override fun onDestroy() {
        runCatching { unregisterReceiver(screenOff) } // not registered when there was no form to fill
        records = null
        // Queued behind any unlock still running, so one finishing after this screen closed is locked too.
        if (::engine.isInitialized) { val e = engine; kotlinx.coroutines.CoroutineScope(vaultQueue).launch { e.lock() } }
        super.onDestroy()
    }

    private fun unlock(action: () -> List<VaultRecord>) {
        if (busy || !::engine.isInitialized) return
        busy = true; message = ""
        lifecycleScope.launch {
            try { val loaded = withContext(vaultQueue) { action() }; records = AutofillMatch.candidates(loaded) }
            catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) {
                val status = withContext(vaultQueue) {
                    engine.lock()
                    runCatching { engine.remainingAttempts() }.getOrDefault(0) to runCatching { engine.isErased() }.getOrDefault(false)
                }
                remaining = status.first; val erased = status.second
                message = if (e is AuthenticationFailure && !erased) getString(R.string.main_incorrect_password, remaining) else e.message ?: getString(R.string.main_operation_failed)
            } finally { busy = false }
        }
    }
    private fun biometrics() {
        if (BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) != BiometricManager.BIOMETRIC_SUCCESS) { message = getString(R.string.main_biometric_not_enrolled); return }
        lifecycleScope.launch {
            try {
                val cipher = withContext(vaultQueue) { engine.biometricCipher(false) }
                biometricPrompt.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle(getString(R.string.main_unlock_passvault)).setSubtitle(getString(R.string.autofill_for, targetName))
                    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG).setNegativeButtonText(getString(R.string.main_use_app_password)).build(), BiometricPrompt.CryptoObject(cipher))
            } catch (_: KeyPermanentlyInvalidatedException) { biometricEnabled = false; message = getString(R.string.main_biometrics_changed) }
            catch (e: Exception) { message = e.message ?: getString(R.string.main_biometric_key_unavailable) }
        }
    }
    /** Hands [record]'s username and password to the waiting app and closes, which locks the vault. */
    private fun fill(record: VaultRecord) {
        if (busy || isFinishing) return
        busy = true
        lifecycleScope.launch {
            try {
                val valid = withContext(vaultQueue) { engine.isUnlocked() }
                if (!valid || isFinishing || !lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) { finish(); return@launch }
                val dataset = PassVaultAutofillService.dataset(this@AutofillActivity, form, record) ?: run { message = getString(R.string.autofill_nothing_to_fill); return@launch }
                setResult(RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset))
                finish()
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (_: Exception) { finish() }
            finally { busy = false }
        }
    }

    @Composable private fun UnlockScreen() {
        var password by remember { mutableStateOf("") }; var visible by remember { mutableStateOf(false) }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Image(painterResource(R.drawable.vault_icon), stringResource(R.string.main_logo_description), Modifier.size(88.dp))
            Spacer(Modifier.height(16.dp)); Text(stringResource(R.string.autofill_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.autofill_for, targetName), Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            Spacer(Modifier.height(28.dp))
            OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.main_app_password)) }, visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password), singleLine = true, shape = RoundedCornerShape(12.dp),
                trailingIcon = { IconButton(onClick = { visible = !visible }) { Icon(if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (visible) stringResource(R.string.main_hide_password) else stringResource(R.string.main_show_password)) } })
            Button(onClick = { val value = password; password = ""; unlock { engine.unlock(value) } }, enabled = ready && password.isNotEmpty(), modifier = Modifier.fillMaxWidth().padding(top = 16.dp).height(52.dp)) { Text(stringResource(R.string.main_unlock_vault)) }
            if (biometricEnabled) OutlinedButton(onClick = { biometrics() }, Modifier.fillMaxWidth().padding(top = 8.dp).height(52.dp)) { Icon(Icons.Default.Fingerprint, null); Text("  " + stringResource(R.string.main_unlock_with_biometrics)) }
            Text(stringResource(R.string.main_attempts_remaining, remaining), Modifier.padding(top = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = { finish() }, Modifier.padding(top = 8.dp)) { Text(stringResource(R.string.main_cancel)) }
        }
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun PickScreen(logins: List<VaultRecord>) {
        var query by remember { mutableStateOf("") }; var confirming by remember { mutableStateOf<VaultRecord?>(null) }
        val appName = remember { PassVaultAutofillService.appLabel(this, form.target.packageName) }
        val suggested by produceState<List<VaultRecord>>(emptyList(), logins) {
            value = withContext(Dispatchers.Default) { logins.filter { AutofillMatch.suggests(it, form.target, appName.takeIf { form.target.site == null }) }.sortedWith(compareBy({ !it.favorite }, { it.name.lowercase() })) }
        }
        val shown = if (query.isBlank()) (if (suggested.isEmpty()) logins.sortedWith(compareBy({ !it.favorite }, { it.name.lowercase() })) else suggested)
            else logins.filter { it.matches(query) }.sortedWith(compareBy({ it !in suggested }, { !it.favorite }, { it.name.lowercase() }))
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            topBar = { TopAppBar(title = { Column { Text(stringResource(R.string.autofill_title)); Text(stringResource(R.string.autofill_for, targetName), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis) } },
                navigationIcon = { IconButton(onClick = { finish() }) { Icon(Icons.Default.Close, stringResource(R.string.main_cancel)) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
            Column(Modifier.padding(padding).padding(horizontal = 16.dp)) {
                TextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text(stringResource(R.string.main_search)) }, leadingIcon = { Icon(Icons.Default.Search, null) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Default.Close, stringResource(R.string.main_clear_search)) } }, singleLine = true, shape = RoundedCornerShape(28.dp),
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                    colors = TextFieldDefaults.colors(focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh, focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh))
                SectionTitle(stringResource(when { query.isNotBlank() -> R.string.main_search; suggested.isNotEmpty() -> R.string.autofill_suggested; else -> R.string.autofill_all_logins }), Modifier.padding(top = 8.dp))
                if (shown.isEmpty()) Text(stringResource(if (logins.isEmpty()) R.string.autofill_no_logins else R.string.autofill_no_results), Modifier.fillMaxWidth().padding(top = 24.dp), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (query.isBlank() && suggested.isEmpty() && logins.isNotEmpty()) Text(stringResource(R.string.autofill_no_match), Modifier.padding(start = 4.dp, bottom = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 32.dp)) {
                    items(shown, key = { it.id }) { record ->
                        Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                            Row(Modifier.clickable { confirming = record }.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                RecordAvatar(record)
                                Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                                    Text(record.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    (AutofillMatch.username(record) ?: record.website).takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Suggested is not verified: names, package names and browser addresses can be spoofed. Every fill needs explicit consent.
        confirming?.let { record ->
            AlertDialog(onDismissRequest = { confirming = null }, icon = { Icon(Icons.Default.Warning, null) }, title = { Text(stringResource(R.string.autofill_confirm_title)) },
                text = { HardenWindow(); Text(stringResource(R.string.autofill_confirm_body, record.name, targetName)) },
                confirmButton = { TextButton(onClick = { confirming = null; fill(record) }) { Text(stringResource(R.string.autofill_fill)) } },
                dismissButton = { TextButton(onClick = { confirming = null }) { Text(stringResource(R.string.main_cancel)) } })
        }
    }
}
