package app.passvault

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.core.content.FileProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

internal enum class UpdatePhase { IDLE, CHECKING, CURRENT, AVAILABLE, DOWNLOADING, PERMISSION, INSTALLING, ERROR }
internal enum class UpdateSource { GITHUB, LAN, PLAY }
internal data class UpdateUi(
    val source: UpdateSource,
    val phase: UpdatePhase = UpdatePhase.IDLE,
    val version: String? = null,
    val percent: Int = 0,
    val error: String? = null,
) {
    val hasUpdate: Boolean get() = version != null && phase != UpdatePhase.CURRENT
}

/** Release builds, and debug builds given a LAN update server, create this object. Other debug builds never check. */
internal class AppUpdates(
    private val activity: MainActivity,
    private val playLauncher: ActivityResultLauncher<IntentSenderRequest>,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val prefs = activity.getSharedPreferences("updates", Activity.MODE_PRIVATE)
    private val playManager: AppUpdateManager by lazy { AppUpdateManagerFactory.create(activity) }
    private var release: ReleaseUpdate? = null
    private var checking = false
    private var playFlowStarted = false
    private var pendingApk: File? = null
    val source: UpdateSource = when {
        BuildConfig.UPDATE_CHANNEL == "lan" -> UpdateSource.LAN
        BuildConfig.UPDATE_CHANNEL == "play" || installedViaPlay() -> UpdateSource.PLAY
        else -> UpdateSource.GITHUB
    }
    var ui by androidx.compose.runtime.mutableStateOf(UpdateUi(source))
        private set

    init {
        if (source != UpdateSource.PLAY) {
            release = prefs.getString("latest_json", null)?.let { text ->
                runCatching { ReleaseUpdates.selectCached(JSONObject(text), BuildConfig.VERSION_CODE.toLong()) }.getOrNull()
            }
            if (release != null) ui = UpdateUi(source, UpdatePhase.AVAILABLE, release!!.version)
            pendingApk = prefs.getString("pending_apk", null)?.takeIf { it.matches(Regex("PassVault-[0-9]+\\.apk")) }
                ?.let { File(File(activity.cacheDir, "updates"), it) }?.takeIf(File::isFile)
        }
    }

    fun onResume() {
        if (ui.phase == UpdatePhase.INSTALLING) ui = ui.copy(phase = UpdatePhase.AVAILABLE)
        if (source != UpdateSource.PLAY && pendingApk != null && activity.packageManager.canRequestPackageInstalls()) {
            installPending()
        }
        check(false)
    }

    fun close() { scope.cancel() }

    fun check(manual: Boolean) {
        if (checking) return
        if (source == UpdateSource.PLAY) { checkPlay(manual); return }
        val last = prefs.getLong("last_check", 0)
        // The LAN server is checked on every resume; GitHub at most every six hours.
        if (!manual && source == UpdateSource.GITHUB && System.currentTimeMillis() - last in 0 until 6 * 60 * 60 * 1000L) return
        checking = true
        if (manual) ui = ui.copy(phase = UpdatePhase.CHECKING, error = null)
        scope.launch {
            try {
                val (candidate, json) = withContext(Dispatchers.IO) {
                    ReleaseUpdates.fetchLatest(BuildConfig.VERSION_CODE.toLong())
                }
                release = candidate
                prefs.edit().putLong("last_check", System.currentTimeMillis())
                    .putString("latest_json", json).apply()
                ui = if (candidate == null) UpdateUi(source, UpdatePhase.CURRENT)
                    else UpdateUi(source, UpdatePhase.AVAILABLE, candidate.version)
            } catch (error: Exception) {
                if (manual) ui = ui.copy(phase = UpdatePhase.ERROR, error = error.message)
            } finally { checking = false }
        }
    }

    fun update() {
        if (source == UpdateSource.PLAY) { startPlay(); return }
        if (ui.phase == UpdatePhase.DOWNLOADING) return
        scope.launch {
            ui = ui.copy(phase = UpdatePhase.DOWNLOADING, percent = 0, error = null)
            try {
                // Ask again first: a newer build may have replaced the one the last check found (the LAN server keeps
                // only the newest). Offline, fall back to what that check found.
                runCatching { withContext(Dispatchers.IO) { ReleaseUpdates.fetchLatest(BuildConfig.VERSION_CODE.toLong()) } }
                    .getOrNull()?.let { (latest, json) ->
                        release = latest
                        prefs.edit().putLong("last_check", System.currentTimeMillis()).putString("latest_json", json).apply()
                    }
                val candidate = release
                val pending = pendingApk?.takeIf(File::isFile)
                if (pending != null && (candidate == null || pending.name == "PassVault-${candidate.versionCode}.apk")) {
                    installPending(); return@launch
                }
                if (candidate == null) { ui = UpdateUi(source, UpdatePhase.CURRENT); return@launch }
                pending?.delete()
                pendingApk = null
                prefs.edit().remove("pending_apk").apply()
                val directory = File(activity.cacheDir, "updates").apply { mkdirs() }
                val apk = File(directory, "PassVault-${candidate.versionCode}.apk")
                withContext(Dispatchers.IO) {
                    ReleaseUpdates.download(candidate, apk) { percent ->
                        scope.launch { ui = ui.copy(percent = percent) }
                    }
                }
                val archive = activity.packageManager.getPackageArchiveInfo(apk.path, 0)
                if (archive?.packageName != activity.packageName || archive.longVersionCode != candidate.versionCode) {
                    apk.delete()
                    throw IllegalStateException("Downloaded APK does not match this app")
                }
                pendingApk = apk
                prefs.edit().putString("pending_apk", apk.name).apply()
                installPending()
            } catch (error: Exception) {
                ui = ui.copy(phase = UpdatePhase.ERROR, error = error.message)
            }
        }
    }

    private fun installPending() {
        val apk = pendingApk?.takeIf(File::isFile) ?: return
        try {
            if (!activity.packageManager.canRequestPackageInstalls()) {
                ui = ui.copy(phase = UpdatePhase.PERMISSION)
                activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}")))
                return
            }
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                clipData = ClipData.newUri(activity.contentResolver, "PassVault update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            pendingApk = null
            prefs.edit().remove("pending_apk").apply()
            ui = ui.copy(phase = UpdatePhase.INSTALLING)
        } catch (error: Exception) {
            ui = ui.copy(phase = UpdatePhase.ERROR, error = error.message)
        }
    }

    private fun checkPlay(manual: Boolean) {
        checking = true
        if (manual) ui = ui.copy(phase = UpdatePhase.CHECKING, error = null)
        playManager.appUpdateInfo.addOnCompleteListener { task ->
            checking = false
            if (!task.isSuccessful) {
                if (manual) ui = ui.copy(phase = UpdatePhase.ERROR, error = task.exception?.message)
                return@addOnCompleteListener
            }
            val info = task.result
            val available = info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
                info.availableVersionCode() > BuildConfig.VERSION_CODE
            ui = if (available) UpdateUi(source, UpdatePhase.AVAILABLE, info.availableVersionCode().toString())
                else UpdateUi(source, UpdatePhase.CURRENT)
            if (info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS && !playFlowStarted) {
                launchPlayFlow(info)
            }
        }
    }

    private fun startPlay() {
        if (playFlowStarted) return
        playManager.appUpdateInfo.addOnSuccessListener { info ->
            if (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
                info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)) launchPlayFlow(info)
            else openPlayListing()
        }.addOnFailureListener { ui = ui.copy(phase = UpdatePhase.ERROR, error = it.message) }
    }

    private fun launchPlayFlow(info: com.google.android.play.core.appupdate.AppUpdateInfo) {
        try {
            playFlowStarted = playManager.startUpdateFlowForResult(info, playLauncher,
                AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build())
            if (!playFlowStarted) openPlayListing()
        } catch (_: Exception) { openPlayListing() }
    }

    fun onPlayResult(resultCode: Int) {
        playFlowStarted = false
        if (resultCode != Activity.RESULT_OK) ui = ui.copy(phase = UpdatePhase.AVAILABLE)
    }

    private fun openPlayListing() {
        val id = activity.packageName
        try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$id"))) }
        catch (_: Exception) {
            try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$id"))) }
            catch (error: Exception) { ui = ui.copy(phase = UpdatePhase.ERROR, error = error.message) }
        }
    }

    private fun installedViaPlay(): Boolean = try {
        activity.packageManager.getInstallSourceInfo(activity.packageName).installingPackageName == "com.android.vending"
    } catch (_: Exception) { false }
}
