package app.passvault

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.FilterInputStream
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
    /** The vault's file keys, newest first; new files are encrypted to the first. */
    fun of(records: List<VaultRecord>): List<VaultRecord> = records.filter { it.ageIdentity != null }.sortedByDescending { updated(it) }
    private fun updated(record: VaultRecord) = runCatching { Instant.parse(record.updatedAt) }.getOrDefault(Instant.EPOCH)
    fun record(name: String, identity: String, notes: String) = VaultRecord(name = name, type = RecordType.note,
        fields = listOf(VaultField(kind = FieldKind.password, label = AGE_KEY_LABEL, value = identity.trim()), VaultField(kind = FieldKind.note, label = "Notes", value = notes)))
    /** Whether a key was added after the last encrypted backup (or there is none): until then it exists only on this phone. */
    fun needsBackup(keys: List<VaultRecord>, lastBackup: Instant?) = keys.isNotEmpty() && (lastBackup == null || keys.any { updated(it).isAfter(lastBackup) })
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
    fun describe(resolver: ContentResolver, uri: Uri): Picked = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (!c.moveToFirst()) null else Picked(uri, c.getString(0), if (c.isNull(1)) null else c.getLong(1))
        }
    }.getOrNull() ?: Picked(uri, null, null)

    fun encrypt(resolver: ContentResolver, from: Uri, to: Uri, recipient: Age.Recipient, cancelled: () -> Boolean, progress: (Long) -> Unit) = write(resolver, to) { output ->
        open(resolver, from).use { input -> Age.encrypt(Counting(input, cancelled, progress), output, listOf(recipient)) }
    }
    /** Throws [AgeException] (not an age file, not for these keys, changed header) before any output is chosen. */
    fun check(resolver: ContentResolver, uri: Uri, identities: List<Age.Identity>) = open(resolver, uri).use { Age.checkHeader(it, identities) }
    fun decrypt(resolver: ContentResolver, from: Uri, to: Uri, identities: List<Age.Identity>, cancelled: () -> Boolean, progress: (Long) -> Unit) = write(resolver, to) { output ->
        open(resolver, from).use { input -> Age.decrypt(Counting(input, cancelled, progress), output, identities) }
    }
    private fun open(resolver: ContentResolver, uri: Uri): InputStream = resolver.openInputStream(uri) ?: throw java.io.FileNotFoundException()
    /**
     * Writes [to] and, if anything fails or is cancelled, empties and deletes it: a damaged file is only noticed at its end, and the part
     * already written must not be left behind as plaintext (or as a file that looks complete).
     */
    private fun write(resolver: ContentResolver, to: Uri, body: (OutputStream) -> Unit) {
        try { (resolver.openOutputStream(to, "wt") ?: throw java.io.FileNotFoundException()).buffered(Age.CHUNK).use(body) }
        catch (e: Exception) { discard(resolver, to); throw e }
    }
    fun discard(resolver: ContentResolver, uri: Uri) {
        runCatching { resolver.openOutputStream(uri, "wt")?.close() }
        runCatching { DocumentsContract.deleteDocument(resolver, uri) }
    }
    /** Deletes a file the user chose (the original of a file just encrypted); false when its app does not allow it. */
    fun delete(resolver: ContentResolver, uri: Uri) = runCatching { DocumentsContract.deleteDocument(resolver, uri) }.getOrDefault(false)

    private class Counting(input: InputStream, private val cancelled: () -> Boolean, private val progress: (Long) -> Unit) : FilterInputStream(input) {
        private var count = 0L
        override fun read(): Int = super.read().also { if (it >= 0) advance(1) }
        override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { if (it > 0) advance(it) }
        private fun advance(n: Int) { if (cancelled()) throw Cancelled(); count += n; progress(count) }
    }
}
