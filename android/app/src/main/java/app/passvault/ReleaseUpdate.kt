package app.passvault

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

internal data class ReleaseUpdate(
    val version: String,
    val versionCode: Long,
    val apkName: String,
    val apkUrl: String,
    val checksumUrl: String,
    val size: Long,
)

/** The release script publishes exactly one versioned APK and a matching SHA256SUMS asset. */
internal object ReleaseUpdates {
    const val API = "https://api.github.com/repos/daocha/password-vault/releases/latest"
    private const val MAX_APK_BYTES = 300_000_000L
    private val apkPattern = Regex("^PassVault-(.+)-([1-9][0-9]*)\\.apk$")
    private val shaPattern = Regex("^[0-9a-fA-F]{64}$")

    fun select(json: JSONObject, installedCode: Long): ReleaseUpdate? {
        if (json.optBoolean("draft") || json.optBoolean("prerelease")) return null
        val tag = json.optString("tag_name")
        val assets = json.optJSONArray("assets") ?: return null
        for (i in 0 until assets.length()) {
            val apk = assets.optJSONObject(i) ?: continue
            val name = apk.optString("name")
            val match = apkPattern.matchEntire(name) ?: continue
            val version = match.groupValues[1]
            val code = match.groupValues[2].toLongOrNull() ?: continue
            if (tag != "v$version" || code <= installedCode) continue
            val size = apk.optLong("size", -1)
            if (size !in 1..MAX_APK_BYTES) continue
            val apkUrl = apk.optString("browser_download_url")
            if (!isReleaseUrl(apkUrl)) continue
            val checksumName = "PassVault-$version-$code.SHA256SUMS"
            val checksum = (0 until assets.length()).mapNotNull(assets::optJSONObject)
                .firstOrNull { it.optString("name") == checksumName } ?: continue
            val checksumUrl = checksum.optString("browser_download_url")
            if (!isReleaseUrl(checksumUrl)) continue
            return ReleaseUpdate(version, code, name, apkUrl, checksumUrl, size)
        }
        return null
    }

    private fun isReleaseUrl(value: String): Boolean = try {
        val url = URL(value)
        url.protocol == "https" && url.host.equals("github.com", ignoreCase = true) &&
            url.path.startsWith("/daocha/password-vault/releases/download/")
    } catch (_: Exception) { false }

    fun checksum(text: String, apkName: String): String? = text.lineSequence().mapNotNull { line ->
        val parts = line.trim().split(Regex("\\s+"), limit = 2)
        if (parts.size == 2 && shaPattern.matches(parts[0]) && parts[1].removePrefix("*") == apkName)
            parts[0].lowercase() else null
    }.firstOrNull()

    fun fetchLatest(installedCode: Long): Pair<ReleaseUpdate?, String?> {
        val response = read(API, 1_000_000)
        if (response == null) return null to null // No published release yet.
        val release = select(JSONObject(response), installedCode)
        return release to if (release == null) null else response
    }

    fun download(release: ReleaseUpdate, destination: File, progress: (Int) -> Unit) {
        val checksumText = read(release.checksumUrl, 100_000) ?: throw IOException("Missing checksum")
        val expected = checksum(checksumText, release.apkName) ?: throw IOException("Invalid checksum")
        val partial = File(destination.parentFile, "${destination.name}.part")
        partial.delete()
        destination.delete()
        val connection = connect(release.apkUrl)
        try {
            if (connection.contentLengthLong > MAX_APK_BYTES) throw IOException("APK is too large")
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            var lastPercent = -1
            partial.outputStream().buffered().use { output ->
                connection.inputStream.buffered().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_APK_BYTES) throw IOException("APK is too large")
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                        val percent = (total * 100 / release.size).toInt().coerceIn(0, 99)
                        if (percent != lastPercent) { progress(percent); lastPercent = percent }
                    }
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (total != release.size || actual != expected) throw IOException("APK verification failed")
            if (!partial.renameTo(destination)) throw IOException("Could not save APK")
            progress(100)
        } finally {
            connection.disconnect()
            partial.delete()
        }
    }

    private fun read(url: String, limit: Int): String? {
        val connection = connect(url, allow404 = true)
        try {
            if (connection.responseCode == HttpURLConnection.HTTP_NOT_FOUND) return null
            connection.inputStream.buffered().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) throw IOException("Response is too large")
                    output.write(buffer, 0, count)
                }
                return output.toString(Charsets.UTF_8.name())
            }
        } finally { connection.disconnect() }
    }

    private fun connect(value: String, allow404: Boolean = false): HttpURLConnection {
        var next = URL(value)
        repeat(6) {
            if (next.protocol != "https") throw IOException("Insecure update URL")
            val connection = (next.openConnection() as HttpURLConnection).apply {
                connectTimeout = 10_000
                readTimeout = 30_000
                instanceFollowRedirects = false
                setRequestProperty("Accept", "application/vnd.github+json")
                setRequestProperty("User-Agent", "PassVault-Android")
            }
            val code = connection.responseCode
            if (code in 300..399) {
                val location = connection.getHeaderField("Location") ?: throw IOException("Missing redirect")
                next = URL(next, location)
                connection.disconnect()
            } else {
                if (code == HttpURLConnection.HTTP_OK || (allow404 && code == HttpURLConnection.HTTP_NOT_FOUND)) return connection
                connection.disconnect()
                throw IOException("Update server returned $code")
            }
        }
        throw IOException("Too many redirects")
    }
}
