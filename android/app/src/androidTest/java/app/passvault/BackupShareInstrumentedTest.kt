package app.passvault

import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Sending a backup to a nearby device: the provider serves only the shared copy, and the intent goes to the chosen app alone. */
class BackupShareInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    @After fun clean() { BackupShareFiles.sweep(context.cacheDir) }

    @Test fun theSharedCopyIsReadableThroughTheProviderOnly() {
        val file = BackupShareFiles.write(context.cacheDir, "passvault_test.pvault", byteArrayOf(7, 8, 9))
        val uri = BackupShareFiles.uri(context, file)
        assertEquals("content", uri.scheme)
        assertEquals(context.packageName + ".backupshare", uri.authority)
        assertArrayEquals(byteArrayOf(7, 8, 9), context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
        // Nothing else in the app's storage can be handed out.
        val other = File(context.cacheDir, "other.bin").apply { writeBytes(byteArrayOf(1)) }
        try { assertThrows(IllegalArgumentException::class.java) { BackupShareFiles.uri(context, other) } } finally { other.delete() }
        assertThrows(IllegalArgumentException::class.java) { BackupShareFiles.uri(context, File(context.filesDir, "vault.bin")) }
    }

    @Test fun theIntentNamesTheChosenAppAndGrantsReadOnly() {
        val file = BackupShareFiles.write(context.cacheDir, "passvault_test.pvault", byteArrayOf(1))
        val uri = BackupShareFiles.uri(context, file)
        val target = NearbyShare.Target("com.google.android.gms", "com.google.android.gms.nearby.sharing.ShareSheetActivity", "Quick Share")
        val intent = NearbyShare.intent(uri, "passvault_test.pvault", target)
        assertEquals(Intent.ACTION_SEND, intent.action)
        assertEquals(NearbyShare.TYPE, intent.type)
        assertEquals(target.packageName, intent.component?.packageName)
        assertEquals(target.activityName, intent.component?.className)
        @Suppress("DEPRECATION") assertEquals(uri, intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM))
        assertEquals(uri, intent.clipData?.getItemAt(0)?.uri)
        assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertEquals(0, intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    }

    @Test fun onlyTrustedSharingAppsAreOffered() {
        // Whatever this device has installed, every offered app passes the allow-list and is preinstalled.
        for (target in NearbyShare.targets(context.packageManager)) {
            val info = context.packageManager.getApplicationInfo(target.packageName, 0)
            val system = info.flags and (android.content.pm.ApplicationInfo.FLAG_SYSTEM or android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            assertTrue(target.toString(), NearbyShare.trusted(target.packageName, target.activityName, system))
        }
    }
}
