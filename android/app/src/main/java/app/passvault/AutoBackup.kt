package app.passvault

import android.content.ContentResolver
import android.content.SharedPreferences
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Automatic backups: after changes, the vault saves an encrypted backup by itself to a folder the user chose once, when it locks or the
 * user leaves the app. Each backup is a new dated file and none is ever deleted, so an entry deleted by mistake can still be found in an
 * older backup; the user removes old ones when they like. The app never goes online: the app that owns the folder (Google Drive,
 * OneDrive, a cloud app that backs up a phone folder, an SD card…) copies the file elsewhere. Same rules on iOS.
 */
class AutoBackupSettings(private val prefs: SharedPreferences, private val prefix: String = "") {
    /** Why the last automatic backup failed, kept until the next one succeeds. */
    enum class Problem { keyGone, noAccess, writeFailed }

    /** Only a folder counts: test builds briefly offered a single file replaced each time, which loses older backups. */
    val enabled get() = prefs.getString(prefix + "autoBackupMode", null) == FOLDER && locationText != null && sealedKey != null
    private val locationText: String? get() = prefs.getString(prefix + "autoBackupUri", null)
    /** The picked folder's tree URI. */
    val location: Uri? get() = locationText?.let(Uri::parse)
    /** The folder name shown in Settings. */
    val name: String get() = prefs.getString(prefix + "autoBackupName", null) ?: ""
    /** [VaultEngine.sealAutoBackupKey]: only this vault's data key opens it. */
    val sealedKey: ByteArray? get() = prefs.getString(prefix + "autoBackupKey", null)?.let { java.util.Base64.getDecoder().decode(it) }
    /** [VaultCrypto.backupDigest] of what the last automatic backup held. */
    val lastDigest: ByteArray? get() = prefs.getString(prefix + "autoBackupDigest", null)?.let { java.util.Base64.getDecoder().decode(it) }
    val lastAutomatic: Instant? get() = prefs.getLong(prefix + "autoBackupAt", 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli)
    val problem: Problem? get() = runCatching { Problem.valueOf(prefs.getString(prefix + "autoBackupProblem", null) ?: "") }.getOrNull()

    /** [location]: the picked folder's tree URI, as text. */
    fun turnOn(location: String, name: String, sealedKey: ByteArray) = synchronized(prefs) {
        prefs.edit().putString(prefix + "autoBackupMode", FOLDER).putString(prefix + "autoBackupUri", location).putString(prefix + "autoBackupName", name)
            .putString(prefix + "autoBackupKey", java.util.Base64.getEncoder().encodeToString(sealedKey)).remove(prefix + "autoBackupDigest").remove(prefix + "autoBackupProblem").apply()
    }
    fun succeeded(digest: ByteArray, at: Instant) = synchronized(prefs) {
        prefs.edit().putString(prefix + "autoBackupDigest", java.util.Base64.getEncoder().encodeToString(digest)).putLong(prefix + "autoBackupAt", at.toEpochMilli()).remove(prefix + "autoBackupProblem").apply()
    }
    fun failed(problem: Problem) { prefs.edit().putString(prefix + "autoBackupProblem", problem.name).apply() }
    /** Turns automatic backups off and forgets the folder, key and history (also when the vault is removed or replaced). */
    fun clear() = synchronized(prefs) {
        prefs.edit().apply { for (key in KEYS) remove(prefix + key) }.apply()
    }
    companion object {
        private const val FOLDER = "folder"
        val KEYS = listOf("autoBackupMode", "autoBackupUri", "autoBackupName", "autoBackupKey", "autoBackupDigest", "autoBackupAt", "autoBackupProblem")
    }
}

/** Automatic backup files: a new dated file each time, in the chosen folder. Nothing is deleted. */
object AutoBackupFiles {
    /** e.g. passvault_auto_2026-11-19_10_31_05.pvault, in local time: names sort by age. */
    fun name(at: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
        "passvault_auto_" + LocalDateTime.ofInstant(at, zone).format(DateTimeFormatter.ofPattern("yyyy-MM-dd_HH_mm_ss")) + ".pvault"

    /** Somewhere to create a new file. */
    fun interface Folder { fun create(name: String, bytes: ByteArray) }
    /** Writes [bytes] as a new file in [folder]; returns its name. */
    fun writeToFolder(folder: Folder, bytes: ByteArray, at: Instant): String = name(at).also { folder.create(it, bytes) }

    /** The folder at [uri]: a picked folder (tree URI with a persisted grant), or a plain directory (file URI, used by device tests). */
    fun folder(resolver: ContentResolver, uri: Uri): Folder =
        if (uri.scheme == "file") Folder { name, bytes -> java.io.File(uri.path!!, name).also { check(!it.exists()) }.writeBytes(bytes) }
        else TreeFolder(resolver, uri)

    /** A folder the user picked with the system folder picker. */
    class TreeFolder(private val resolver: ContentResolver, tree: Uri) : Folder {
        private val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        override fun create(name: String, bytes: ByteArray) {
            val uri = DocumentsContract.createDocument(resolver, parent, NearbyShare.TYPE, name) ?: throw java.io.IOException("Cannot create the backup file.")
            // A partial file is emptied and deleted, so it never looks like a complete backup.
            FileCrypt.writeWhole(resolver, uri, bytes)
        }
    }
}

/**
 * Runs automatic backups outside the activity, so leaving the app (which may destroy it) does not stop a backup half way. One at a
 * time: a second request for the same records is skipped by the digest check inside the lock.
 */
object AutoBackupRunner {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    /** [skipped]: turned off meanwhile. */
    enum class Result { saved, unchanged, skipped, failed }

    /**
     * Writes [ready] to the folder in [settings] and records it as a backup in the source vault's history ([VaultExport.recordBackup]).
     * [done] runs on the IO thread with the result.
     */
    fun write(resolver: ContentResolver, prefs: SharedPreferences, settings: AutoBackupSettings, ready: VaultEngine.Automatic.Ready, force: Boolean, done: (Result) -> Unit = {}) {
        scope.launch {
            val result = lock.withLock {
                try {
                    if (!force && settings.lastDigest?.let { java.security.MessageDigest.isEqual(it, ready.digest) } == true) return@withLock Result.unchanged
                    val location = settings.location?.takeIf { settings.enabled } ?: return@withLock Result.skipped
                    val now = Instant.now()
                    AutoBackupFiles.writeToFolder(AutoBackupFiles.folder(resolver, location), ready.export.bytes, now)
                    settings.succeeded(ready.digest, now)
                    ready.export.recordBackup(prefs, now)
                    Result.saved
                } catch (e: SecurityException) { settings.failed(AutoBackupSettings.Problem.noAccess); Result.failed }
                catch (e: java.io.FileNotFoundException) { settings.failed(AutoBackupSettings.Problem.noAccess); Result.failed }
                catch (e: Exception) { settings.failed(AutoBackupSettings.Problem.writeFailed); Result.failed }
                finally { ready.export.clear() }
            }
            done(result)
        }
    }
}
