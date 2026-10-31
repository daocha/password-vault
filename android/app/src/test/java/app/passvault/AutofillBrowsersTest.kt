package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class AutofillBrowsersTest {
    private val chrome = "f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83"
    private val chromeUserdebug = "1975b2f17177bc89a5dff31f9e64a6cae281a53dc1d1d59b1d147fe1c82afa00"
    private val firefox = "a78b62a5165b4494b2fead9e76a280d22d937fee6251aece599446b2ea319b04"
    private val other = "00".repeat(32)

    @Test fun onlyTheBrowsersOwnReleaseCertificateCounts() {
        assertTrue(AutofillBrowsers.trusts("com.android.chrome", listOf(chrome), lineage = true))
        assertTrue(AutofillBrowsers.trusts("org.mozilla.firefox", listOf(firefox), lineage = true))
        // A sideloaded app taking Firefox's package name is signed with another key.
        assertFalse(AutofillBrowsers.trusts("org.mozilla.firefox", listOf(other), lineage = true))
        // Another browser's key does not carry over, and test-build keys are left out.
        assertFalse(AutofillBrowsers.trusts("org.mozilla.firefox", listOf(chrome), lineage = true))
        assertFalse(AutofillBrowsers.trusts("com.android.chrome", listOf(chromeUserdebug), lineage = true))
        assertFalse(AutofillBrowsers.trusts("com.android.chrome", emptyList(), lineage = true))
        // A rotated key: any certificate in the proven lineage counts. Several current signers must all be trusted.
        assertTrue(AutofillBrowsers.trusts("com.android.chrome", listOf(chrome, other), lineage = true))
        assertFalse(AutofillBrowsers.trusts("com.android.chrome", listOf(chrome, other), lineage = false))
        // Apps in Google's list that are not browsers (Play services) never supply a website here.
        assertFalse(AutofillBrowsers.trusts("com.google.android.gms", listOf(chrome), lineage = true))
        assertFalse(AutofillBrowsers.trusts("org.torproject.torbrowser", listOf(other), lineage = true))
    }

    @Test fun manifestQueriesListExactlyTheVerifiableBrowsers() {
        // Without a <queries> entry, Android 11+ hides the browser and its signature cannot be read, so it would never verify.
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val queried = Regex("""<package android:name="([^"]+)"""").findAll(manifest.substringAfter("<queries>").substringBefore("</queries>")).map { it.groupValues[1] }.toSet()
        assertEquals(23, AutofillBrowsers.packages.size)
        assertEquals(AutofillBrowsers.packages, queried)
        assertTrue(AutofillBrowsers.packages.all { it in AutofillTarget.BROWSERS })
    }

    @Test fun fingerprintIsLowercaseSha256Hex() {
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", AutofillBrowsers.fingerprint(ByteArray(0)))
    }
}
