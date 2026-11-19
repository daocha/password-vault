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

/** The minimum time between successful automatic backups. Monthly is 30 days on both platforms. */
enum class AutoBackupFrequency(val seconds: Long) {
    instant(0), daily(86_400), weekly(7 * 86_400), monthly(30 * 86_400);

    fun remainingMillis(last: Instant?, now: Instant): Long =
        if (last == null || this == instant) 0 else (seconds * 1000 - java.time.Duration.between(last, now).toMillis()).coerceAtLeast(0)
}

/**
 * Automatic backups: save changes instantly by default, or after the chosen interval since the last successful backup. Each backup is a new dated file and none is ever deleted, so an entry deleted by mistake can still be found in an
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
    var frequency: AutoBackupFrequency
        get() = runCatching { AutoBackupFrequency.valueOf(prefs.getString(prefix + "autoBackupFrequency", null) ?: "") }.getOrDefault(AutoBackupFrequency.instant)
        set(value) { prefs.edit().putString(prefix + "autoBackupFrequency", value.name).apply() }
    fun remainingMillis(now: Instant = Instant.now()): Long = frequency.remainingMillis(lastAutomatic, now)
    val problem: Problem? get() = runCatching { Problem.valueOf(prefs.getString(prefix + "autoBackupProblem", null) ?: "") }.getOrNull()

    /** [location]: the picked folder's tree URI, as text. */
    fun turnOn(location: String, name: String, sealedKey: ByteArray) = synchronized(prefs) {
        prefs.edit().putString(prefix + "autoBackupMode", FOLDER).putString(prefix + "autoBackupUri", location).putString(prefix + "autoBackupName", name)
            .putString(prefix + "autoBackupKey", java.util.Base64.getEncoder().encodeToString(sealedKey)).remove(prefix + "autoBackupDigest").remove(prefix + "autoBackupAt").remove(prefix + "autoBackupProblem").apply()
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
        val KEYS = listOf("autoBackupMode", "autoBackupUri", "autoBackupName", "autoBackupKey", "autoBackupDigest", "autoBackupAt", "autoBackupProblem", "autoBackupFrequency")
    }
}

/** Automatic backup files: a new dated file each time, in the chosen folder. Nothing is deleted. */
object AutoBackupFiles {
    private const val PREFIX = "passvault_auto_"
    private const val EXTENSION = ".pvault"
    /** How many backups Settings lists. */
    const val RECENT = 5

    /** e.g. passvault_auto_2026-11-19_10_31_05.pvault, in local time: names sort by age. */
    fun name(at: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
        PREFIX + LocalDateTime.ofInstant(at, zone).format(DateTimeFormatter.ofPattern("yyyy-MM-dd_HH_mm_ss")) + EXTENSION

    /**
     * [name], or, when that is [taken] (a second backup within the same second), the same name ending _2, _3… before the extension.
     * These still sort after the first one.
     */
    fun uniqueName(at: Instant, zone: ZoneId = ZoneId.systemDefault(), taken: (String) -> Boolean): String {
        val first = name(at, zone)
        if (!taken(first)) return first
        val stem = first.removeSuffix(EXTENSION)
        return (2..10_000).asSequence().map { "${stem}_$it$EXTENSION" }.firstOrNull { !taken(it) } ?: throw java.io.IOException("Too many backups in one second.")
    }

    /** Whether [name] is an automatic backup's file name (also the longer names earlier test builds gave them). */
    fun isAutomatic(name: String) = name.startsWith(PREFIX) && name.endsWith(EXTENSION)

    /**
     * The newest [limit] automatic backups among [names] (a folder's files), newest first: by the time in the name, then by the number a
     * second backup within the same second ends with (so _10 comes after _9).
     */
    fun newest(names: Iterable<String>, limit: Int = RECENT): List<String> =
        names.filter(::isAutomatic).distinct().sortedWith(compareByDescending<String> { age(it).first }.thenByDescending { age(it).second }.thenByDescending { it }).take(limit)

    /**
     * The time written in an automatic backup's name and its number within that second: 1 for none, N for "_N", N+1 for " (N)" (a copy
     * the folder's app renamed). Longer names from earlier test builds count as 1.
     */
    private fun age(name: String): Pair<String, Int> {
        val rest = name.removePrefix(PREFIX).removeSuffix(EXTENSION)
        val time = rest.take(19); val tail = rest.drop(19)
        tail.takeIf { it.startsWith("_") }?.drop(1)?.toIntOrNull()?.takeIf { it > 0 }?.let { return time to it }
        if (tail.startsWith(" (") && tail.endsWith(")")) tail.drop(2).dropLast(1).toIntOrNull()?.takeIf { it >= 0 }?.let { return time to it + 1 }
        return time to 1
    }

    /** Somewhere to create a new file. [exists]: whether it already has a file of that name, when that can be told cheaply. */
    fun interface Folder {
        fun create(name: String, bytes: ByteArray)
        fun exists(name: String): Boolean = false
    }
    /** The names written in this process, for a picked folder that cannot cheaply tell whether a name is taken. */
    private val written = HashSet<String>()
    /** Writes [bytes] as a new file in [folder]; returns its name. Callers write one backup at a time ([AutoBackupRunner]). */
    fun writeToFolder(folder: Folder, bytes: ByteArray, at: Instant): String = synchronized(written) {
        if (written.size > 1_000) written.clear()
        uniqueName(at) { it in written || folder.exists(it) }.also { folder.create(it, bytes); written += it }
    }

    /** The folder at [uri]: a picked folder (tree URI with a persisted grant), or a plain directory (file URI, used by device tests). */
    fun folder(resolver: ContentResolver, uri: Uri): Folder =
        if (uri.scheme == "file") object : Folder {
            override fun create(name: String, bytes: ByteArray) { java.io.File(uri.path!!, name).also { check(!it.exists()) }.writeBytes(bytes) }
            override fun exists(name: String) = java.io.File(uri.path!!, name).exists()
        }
        else TreeFolder(resolver, uri)

    /**
     * The names of the files in the folder at [uri], to list the newest backups. Throws [SecurityException] when PassVault no longer
     * has access to the folder (its grant was revoked, or the folder was removed).
     */
    fun list(resolver: ContentResolver, uri: Uri): List<String> {
        if (uri.scheme == "file") return java.io.File(uri.path!!).list()?.toList() ?: throw SecurityException("The folder cannot be read.")
        if (resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }) throw SecurityException("No access to the folder.")
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        val cursor = resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null) ?: throw SecurityException("The folder cannot be read.")
        return cursor.use { buildList { while (it.moveToNext()) it.getString(0)?.let(::add) } }
    }

/** A folder the user picked with the system folder picker. A provider that already has a file of the same name keeps both. */
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
                    // Recheck inside the writer lock: a preceding queued backup may have just reset the interval.
                    if (!force && settings.remainingMillis() > 0) return@withLock Result.unchanged
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
