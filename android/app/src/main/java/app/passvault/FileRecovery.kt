package app.passvault

import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Durable ownership of external outputs, independent of activity/process lifetime. FileJobs serializes all callers, including recovery
 * and acknowledgment. Record after opening an empty destination, before writing bytes; forget only after cleanup or accepted success.
 * A provider can retain plaintext already handed to it. Restart cleanup cannot revoke those copies or run while the app is stopped.
 */
internal class FileRecovery(private val context: Context) {
    data class Pending(val id: String, val source: FileVault, val uri: Uri, val name: String, val plaintext: Boolean, val grant: Int)
    private val resolver = context.contentResolver
    private val storage = ProtectedStorage(context)

    fun pending(): List<Pending> {
        val bytes = storage.readFileRecovery() ?: return emptyList()
        try {
            val array = JSONArray(String(bytes, Charsets.UTF_8))
            require(array.length() <= 128)
            return (0 until array.length()).map { i -> array.getJSONObject(i).let { o ->
                Pending(o.getString("id"), FileVault(o.getBoolean("decoy"), o.getLong("instance")), Uri.parse(o.getString("uri")), o.getString("name"), o.getBoolean("plaintext"), o.getInt("grant"))
            } }
        } finally { bytes.fill(0) }
    }
    private fun save(entries: List<Pending>) {
        val array = JSONArray()
        entries.forEach { p -> array.put(JSONObject().put("id", p.id).put("decoy", p.source.decoy).put("instance", p.source.instance)
            .put("uri", p.uri.toString()).put("name", p.name).put("plaintext", p.plaintext).put("grant", p.grant)) }
        val bytes = array.toString().toByteArray(Charsets.UTF_8)
        try { storage.writeFileRecovery(bytes) } finally { bytes.fill(0) }
    }
    fun begin(uri: Uri, source: FileVault, plaintext: Boolean): String {
        val entries = pending()
        check(entries.size < 128 && entries.none { it.uri == uri }) { "An output still needs recovery." }
        // Preserve grants owned by another app feature. Providers without persistable access still get a durable warning on failure.
        val held = resolver.persistedUriPermissions.firstOrNull { it.uri == uri }
        val wanted = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val previous = (if (held?.isReadPermission == true) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
            (if (held?.isWritePermission == true) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        val acquired = runCatching { resolver.takePersistableUriPermission(uri, wanted); wanted and previous.inv() }.getOrDefault(0)
        val entry = Pending(UUID.randomUUID().toString(), source, uri, FileCrypt.describe(resolver, uri).name.orEmpty(), plaintext, acquired)
        try { save(entries + entry) } catch (e: Exception) { release(entry); throw e }
        return entry.id
    }
    fun finish(id: String?) {
        if (id == null) return
        val entries = pending(); val entry = entries.firstOrNull { it.id == id } ?: return
        save(entries.filterNot { it.id == id })
        release(entry)
    }
    private fun release(entry: Pending) {
        if (entry.grant != 0) runCatching { resolver.releasePersistableUriPermission(entry.uri, entry.grant) }
    }
    /** Only called under FileJobs ownership on startup, before another output can be opened. Failed cleanup stays durable until OK. */
    fun recover(discard: (Uri) -> Boolean = { FileCrypt.discard(resolver, it) }): List<Pending> {
        val entries = pending()
        for (entry in entries) if (discard(entry.uri)) finish(entry.id)
        return pending()
    }
}
