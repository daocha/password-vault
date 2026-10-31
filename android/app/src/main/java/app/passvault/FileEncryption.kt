package app.passvault

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.FilterInputStream
import java.io.FilterOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.time.Instant

/** The stored label of the field that holds a file-encryption key (an age identity). Kept in English, shown translated. */
const val AGE_KEY_LABEL = "age secret key"

/**
 * A file-encryption key is an ordinary secure note with one password field labelled [AGE_KEY_LABEL] holding an age identity, so it moves
 * with backups and phone transfers like any entry, and other PassVault apps (iOS, older Android) keep and show it as a note.
 */
val VaultRecord.ageIdentity: String? get() =
    if (type != RecordType.note) null else fields.firstOrNull { it.kind == FieldKind.password && it.label == AGE_KEY_LABEL }?.value?.takeIf(Age::isIdentity)?.trim()

object FileKeys {
    /** Hidden metadata (kept by backups, transfers and iOS) holding when the key was added. */
    const val CREATED = "fileKeyCreated"
    /** The vault's file keys, newest first; new files are encrypted to the first. */
    fun of(records: List<VaultRecord>): List<VaultRecord> = records.filter { it.ageIdentity != null }.sortedByDescending { created(it) }
    /**
     * When the key was added. Not `updatedAt`: moving an old key to a group or starring it must not make it the active key again (after
     * rotating away from a key that leaked, say). Falls back to `updatedAt` only for a key entry without the stamp.
     */
    fun created(record: VaultRecord): Instant = (record.legacy[CREATED] ?: record.updatedAt).let { runCatching { Instant.parse(it) }.getOrDefault(Instant.EPOCH) }
    fun record(name: String, identity: String, notes: String, now: Instant = Instant.now()) = VaultRecord(name = name, type = RecordType.note, updatedAt = now.toString(),
        fields = listOf(VaultField(kind = FieldKind.password, label = AGE_KEY_LABEL, value = identity.trim()), VaultField(kind = FieldKind.note, label = "Notes", value = notes)),
        legacy = mapOf(CREATED to now.toString()))
    /**
     * A key created to encrypt new files. It is stamped after the newest of [existing] even when the clock is behind it (set back, or a
     * restored key stamped in the future), so creating a key always rotates to it.
     */
    fun newKey(name: String, identity: String, notes: String, existing: List<VaultRecord>, now: Instant = Instant.now()): VaultRecord {
        val added = existing.maxOfOrNull(::created)?.plusMillis(1)?.takeIf { it > now } ?: now
        return record(name, identity, notes, now).let { it.copy(legacy = it.legacy + (CREATED to added.toString())) }
    }
    /**
     * A key pasted in (from age-keygen, say) to open files encrypted to it. It does not take over encryption: it is stamped just before
     * the oldest of [existing] (the vault's keys), so new files keep using the current key. It is used for new files only when it is the
     * vault's first key.
     */
    fun imported(name: String, identity: String, notes: String, existing: List<VaultRecord>, now: Instant = Instant.now()): VaultRecord {
        val added = existing.minOfOrNull(::created)?.minusMillis(1) ?: now
        return record(name, identity, notes, now).let { it.copy(legacy = it.legacy + (CREATED to added.toString())) }
    }
    /**
     * [result] (what an import would leave in the vault) plus every key of [before] whose secret it no longer holds: an import, even a
     * full replacement from an older backup, must never delete a file key, since files encrypted to it could never be opened again. A
     * kept key whose id the import reused (for another secret, or another entry) gets a new id. Deleting a key stays a deliberate act.
     */
    fun keepKeys(before: List<VaultRecord>, result: List<VaultRecord>): List<VaultRecord> {
        val secrets = result.mapNotNull { it.ageIdentity?.uppercase() }.toSet(); val ids = result.map { it.id }.toSet()
        val lost = before.filter { it.ageIdentity?.uppercase()?.let { s -> s !in secrets } == true }
        return if (lost.isEmpty()) result else result + lost.map { if (it.id in ids) it.copy(id = java.util.UUID.randomUUID().toString()) else it }
    }
    /**
     * Gives every key entry without a creation stamp one, from its `updatedAt` as it is now: entries made by earlier builds, by hand on
     * iOS, or restored from such backups. Run whenever records are loaded or saved, so the stamp exists before an edit can bump
     * `updatedAt`. Returns [records] itself when nothing needed stamping.
     */
    fun stamp(records: List<VaultRecord>): List<VaultRecord> {
        if (records.none { it.ageIdentity != null && CREATED !in it.legacy }) return records
        return records.map { if (it.ageIdentity != null && CREATED !in it.legacy) it.copy(legacy = it.legacy + (CREATED to created(it).toString())) else it }
    }
    /**
     * Identifies a key's secret without revealing it, to remember which keys the last backup held (kept in ordinary preferences).
     * The secret is 256 random bits, so its hash cannot be reversed or guessed.
     */
    fun fingerprint(identity: String): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest("PassVault/file-key/v1\n${identity.trim().uppercase()}".toByteArray()).take(16).joinToString("") { "%02x".format(it) }
    /**
     * Whether a key is not in the last encrypted backup, so it exists only on this phone. [backedUp] holds the fingerprints of the keys
     * that backup contained; it compares the secrets themselves, so a key whose secret was replaced (on iOS, say) counts as new. A
     * backup made before fingerprints were recorded ([backedUp] null) cannot establish which secrets it held: request a fresh backup.
     */
    fun needsBackup(keys: List<VaultRecord>, lastBackup: Instant?, backedUp: Set<String>?): Boolean {
        if (keys.isEmpty()) return false
        return lastBackup == null || backedUp == null || keys.any { fingerprint(it.ageIdentity!!) !in backedUp }
    }
    /** `report.pdf` → `report.pdf.age`. */
    fun encryptedName(original: String?) = (original?.takeIf { it.isNotBlank() } ?: "file") + ".age"
    /** `report.pdf.age` → `report.pdf`; a name without `.age` gets `.decrypted` added instead, so the copy never replaces the original. */
    fun decryptedName(encrypted: String?): String {
        val name = encrypted?.takeIf { it.isNotBlank() } ?: "file"
        return name.takeIf { it.endsWith(".age", ignoreCase = true) && it.length > 4 }?.dropLast(4) ?: "$name.decrypted"
    }
}

/** Progress of a file being encrypted or decrypted; [total] is null when the provider does not report the size. */
data class FileProgress(val decrypting: Boolean, val done: Long, val total: Long?)

/** File encryption between the app's own document pickers' URIs. Runs on a background thread; [progress] gets the bytes read so far. */
object FileCrypt {
    class Picked(val uri: Uri, val name: String?, val size: Long?)
    class Cancelled : Exception("Cancelled.")
    /** The job failed or was cancelled and its partial output could not be emptied or deleted: the user must remove it. */
    class LeftBehind(cause: Exception) : Exception("Partial output could not be removed.", cause)
    /**
     * Whether two URIs name the same document, so a job never writes over its own source (truncating it before it is read). The save
     * picker normally creates a new document, but a provider may let the user pick the existing one.
     */
    fun sameDocument(a: Uri, b: Uri): Boolean = a == b || (a.authority == b.authority && runCatching {
        DocumentsContract.getDocumentId(a) == DocumentsContract.getDocumentId(b)
    }.getOrDefault(false))
    fun describe(resolver: ContentResolver, uri: Uri): Picked = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (!c.moveToFirst()) null else Picked(uri, c.getString(0), if (c.isNull(1)) null else c.getLong(1))
        }
    }.getOrNull() ?: Picked(uri, null, null)

    fun encrypt(resolver: ContentResolver, from: Uri, to: Uri, recipient: Age.Recipient, cancelled: () -> Boolean, progress: (Long) -> Unit) = write(resolver, to, cancelled) { output ->
        open(resolver, from).use { input -> Age.encrypt(Counting(input, cancelled, progress), output, listOf(recipient)) }
    }
    /** Throws [AgeException] (not an age file, not for these keys, changed header) before any output is chosen. */
    fun check(resolver: ContentResolver, uri: Uri, identities: List<Age.Identity>) = open(resolver, uri).use { Age.checkHeader(it, identities) }
    fun decrypt(resolver: ContentResolver, from: Uri, to: Uri, identities: List<Age.Identity>, cancelled: () -> Boolean, progress: (Long) -> Unit) = write(resolver, to, cancelled) { output ->
        open(resolver, from).use { input -> Age.decrypt(Counting(input, cancelled, progress), output, identities) }
    }
    private fun open(resolver: ContentResolver, uri: Uri): InputStream = resolver.openInputStream(uri) ?: throw java.io.FileNotFoundException()
    /**
     * Once [to] has been opened for writing, any failure or cancellation empties and deletes it: a damaged file is only noticed at its
     * end, and the part already written must not be left behind as plaintext (or as a file that looks complete). If opening fails, keep
     * any existing content and remove only an empty save target. Cancellation is checked before opening, on every write and once more
     * after the file is closed, since a small file is read in full before anything is written. Throws [LeftBehind] when written output
     * could be neither emptied nor deleted.
     */
    private fun write(resolver: ContentResolver, to: Uri, cancelled: () -> Boolean, body: (OutputStream) -> Unit) {
        val output = try {
            if (cancelled()) throw Cancelled()
            resolver.openOutputStream(to, "wt") ?: throw java.io.FileNotFoundException()
        } catch (e: Exception) { discardUnwritten(resolver, to); throw e }
        try {
            // Unbuffered: Age already writes whole chunks, and a BufferedOutputStream would keep a copy of the last, short chunk of
            // plaintext (all of a small file) in a buffer nobody wipes.
            Checked(output, cancelled).use(body)
            if (cancelled()) throw Cancelled()
        } catch (e: Exception) { if (!discard(resolver, to)) throw LeftBehind(e); throw e }
    }
    /**
     * Writes [bytes] as the whole of [uri] (a backup or transfer file the user chose). If writing fails part way, the partial file is
     * emptied and deleted, so it is never left looking like a complete backup; if it cannot even be opened, only an empty save target is
     * removed. Throws [LeftBehind] when the partial file could be neither emptied nor deleted.
     */
    fun writeWhole(resolver: ContentResolver, uri: Uri, bytes: ByteArray) {
        val output = try { resolver.openOutputStream(uri, "wt") ?: throw java.io.FileNotFoundException() } catch (e: Exception) { discardUnwritten(resolver, uri); throw e }
        try { output.use { it.write(bytes) } } catch (e: Exception) { if (!discard(resolver, uri)) throw LeftBehind(e); throw e }
    }
    /** Empties and deletes [uri]; true when no content is left (it was emptied, deleted, or both). */
    fun discard(resolver: ContentResolver, uri: Uri): Boolean {
        val emptied = runCatching { resolver.openOutputStream(uri, "wt")?.use {} != null }.getOrDefault(false)
        val deleted = runCatching { DocumentsContract.deleteDocument(resolver, uri) }.getOrDefault(false)
        return emptied || deleted
    }
    /**
     * Runs [job] (which writes the output) on [worker], then [accept]s it on the calling thread, where locking also happens, so nothing
     * can stop it between the last [cancelled] check and [accept]. The job removes its own output when it fails or stops itself; a
     * complete output that is never accepted (stopped after the job's last check, or the coroutine cancelled on its way back from
     * [worker]) is removed here with [discard]. Throws [LeftBehind] when that removal fails, except on coroutine cancellation, which is
     * rethrown unchanged (nobody is left to tell).
     */
    suspend fun guarded(worker: kotlin.coroutines.CoroutineContext, cancelled: () -> Boolean, discard: () -> Boolean, job: () -> Unit, accept: () -> Unit) {
        val written = java.util.concurrent.atomic.AtomicBoolean(false); var accepted = false
        try {
            kotlinx.coroutines.withContext(worker) { job(); written.set(true) }
            if (cancelled()) throw Cancelled()
            accepted = true
            accept()
        } catch (e: Exception) {
            if (written.get() && !accepted && !kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + worker) { discard() } && e !is kotlinx.coroutines.CancellationException) throw LeftBehind(e)
            throw e
        }
    }
    /**
     * Deletes [uri], a save picker's result nothing was written to, but only while it is empty: the picker usually creates a new, empty
     * document, but the user may have picked an existing file to replace, and that must not be deleted when the job never starts.
     */
    fun discardUnwritten(resolver: ContentResolver, uri: Uri) {
        val empty = runCatching { open(resolver, uri).use { it.read() == -1 } }.getOrDefault(false)
        if (empty) runCatching { DocumentsContract.deleteDocument(resolver, uri) }
    }
    /** Deletes a file the user chose (the original of a file just encrypted); false when its app does not allow it. */
    fun delete(resolver: ContentResolver, uri: Uri) = runCatching { DocumentsContract.deleteDocument(resolver, uri) }.getOrDefault(false)

    private class Checked(output: OutputStream, private val cancelled: () -> Boolean) : FilterOutputStream(output) {
        override fun write(b: Int) { check(); out.write(b) }
        // FilterOutputStream would otherwise write byte by byte.
        override fun write(b: ByteArray, off: Int, len: Int) { check(); out.write(b, off, len) }
        private fun check() { if (cancelled()) throw Cancelled() }
    }
    private class Counting(input: InputStream, private val cancelled: () -> Boolean, private val progress: (Long) -> Unit) : FilterInputStream(input) {
        private var count = 0L
        override fun read(): Int = super.read().also { if (it >= 0) advance(1) }
        override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { if (it > 0) advance(it) }
        private fun advance(n: Int) { if (cancelled()) throw Cancelled(); count += n; progress(count) }
    }
}
