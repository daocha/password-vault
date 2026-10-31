package app.passvault

import android.content.Context
import android.content.pm.PackageManager
import org.json.JSONObject
import java.security.MessageDigest

/**
 * Whether the requesting app really is the browser its package name says. Any app can take a browser's package name when that browser
 * is not installed, then claim any website, so a reported site counts only from a package in [AutofillTarget.BROWSERS] signed with one
 * of the release certificates in the bundled list (Google's list of browsers privileged for passkeys; see docs/PRIVILEGED-BROWSERS.md).
 */
internal object AutofillBrowsers {
    /** Package name → SHA-256 fingerprints (lowercase hex) of its release signing certificates. Empty, so nothing verifies, if unreadable. */
    private val trusted: Map<String, Set<String>> by lazy {
        runCatching {
            val text = AutofillBrowsers::class.java.getResourceAsStream("/privileged_browsers.json")!!.bufferedReader().use { it.readText() }
            val apps = JSONObject(text).getJSONArray("apps")
            buildMap<String, MutableSet<String>> {
                for (i in 0 until apps.length()) {
                    val app = apps.getJSONObject(i); if (app.optString("type") != "android") continue
                    val info = app.getJSONObject("info"); val name = info.getString("package_name")
                    if (name !in AutofillTarget.BROWSERS) continue
                    val signatures = info.getJSONArray("signatures")
                    for (j in 0 until signatures.length()) {
                        val signature = signatures.getJSONObject(j)
                        if (signature.optString("build") == "release") getOrPut(name) { mutableSetOf() } += normalize(signature.getString("cert_fingerprint_sha256"))
                    }
                }
            }
        }.getOrDefault(emptyMap())
    }

    /** The browsers that can be verified at all; the manifest's <queries> must list exactly these. */
    val packages: Set<String> get() = trusted.keys
    private fun normalize(fingerprint: String) = fingerprint.replace(":", "").lowercase()
    fun fingerprint(certificate: ByteArray) = MessageDigest.getInstance("SHA-256").digest(certificate).joinToString("") { "%02x".format(it) }

    /**
     * [fingerprints]: of the app's current signing certificates when it has several (all must be trusted), or of its certificate lineage
     * when it has one ([lineage]; any proven past or current certificate counts, as Android's own rotation rules allow).
     */
    fun trusts(packageName: String, fingerprints: List<String>, lineage: Boolean): Boolean {
        val allowed = trusted[packageName] ?: return false
        if (fingerprints.isEmpty()) return false
        return if (lineage) fingerprints.any { it in allowed } else fingerprints.all { it in allowed }
    }

    fun verify(context: Context, packageName: String): Boolean = runCatching {
        if (packageName !in AutofillTarget.BROWSERS) return false
        val info = context.packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo ?: return false
        if (info.hasMultipleSigners()) trusts(packageName, info.apkContentsSigners.orEmpty().map { fingerprint(it.toByteArray()) }, lineage = false)
        else trusts(packageName, info.signingCertificateHistory.orEmpty().map { fingerprint(it.toByteArray()) }, lineage = true)
    }.getOrDefault(false)
}
