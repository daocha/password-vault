package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BackupShareTest {
    @Test fun onlyPreinstalledNearbySharingAppsMayReceiveABackup() {
        // Google Quick Share lives in Play services; other Play services activities are not sharing apps.
        assertTrue(NearbyShare.trusted("com.google.android.gms", "com.google.android.gms.nearby.sharing.ShareSheetActivity", system = true))
        assertFalse(NearbyShare.trusted("com.google.android.gms", "com.google.android.gms.auth.SomeShareTarget", system = true))
        for (pkg in listOf("com.samsung.android.app.sharelive", "com.huawei.android.instantshare", "com.miui.mishare.connectivity", "com.coloros.oshare", "com.vivo.share")) {
            assertTrue(pkg, NearbyShare.trusted(pkg, "$pkg.ShareActivity", system = true))
            // A sideloaded app taking the package name on a phone that lacks the real one is not offered.
            assertFalse(pkg, NearbyShare.trusted(pkg, "$pkg.ShareActivity", system = false))
        }
        assertFalse(NearbyShare.trusted("com.google.android.gms", "com.google.android.gms.nearby.sharing.ShareSheetActivity", system = false))
        // Mail, chat and cloud apps are never offered, even when preinstalled.
        for (pkg in listOf("com.google.android.gm", "org.telegram.messenger", "com.whatsapp", "com.tencent.mm", "com.google.android.apps.docs", "com.android.bluetooth", "com.android.email"))
            assertFalse(pkg, NearbyShare.trusted(pkg, "$pkg.Share", system = true))
    }

    @Test fun theSharedCopyIsReplacedAndSweptAway() {
        val cache = Files.createTempDirectory("share").toFile()
        try {
            val first = BackupShareFiles.write(cache, "passvault_2026-11-19_10_00.pvault", byteArrayOf(1, 2, 3))
            assertEquals(File(cache, "backup-share"), first.parentFile)
            assertArrayEquals(byteArrayOf(1, 2, 3), first.readBytes())
            // Each send replaces the earlier copy, and a name cannot climb out of the shared folder.
            val second = BackupShareFiles.write(cache, "../escape.pvault", byteArrayOf(4))
            assertEquals(File(cache, "backup-share/escape.pvault"), second)
            assertFalse(first.exists()); assertFalse(File(cache, "escape.pvault").exists())
            assertTrue(BackupShareFiles.sweep(cache))
            assertFalse(second.exists())
            assertTrue(BackupShareFiles.sweep(File(cache, "missing")))
        } finally { cache.deleteRecursively() }
    }

    @Test fun manifestSharesOnlyTheBackupFolderAndStaysOffline() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertFalse("the main app has no INTERNET permission", manifest.contains("android.permission.INTERNET"))
        val provider = manifest.substringAfter("app.passvault.BackupShareProvider").substringBefore("</provider>")
        assertTrue(provider.contains("android:authorities=\"\${applicationId}.backupshare\""))
        assertTrue(provider.contains("android:exported=\"false\"") && provider.contains("android:grantUriPermissions=\"true\""))
        val paths = File("src/main/res/xml/backup_share_paths.xml").readText().substringAfter("<paths>").substringBefore("</paths>").trim()
        assertEquals("<cache-path name=\"backup\" path=\"${BackupShareFiles.FOLDER}/\" />", paths)
        assertTrue("sharing apps are visible to the app", Regex("""<intent>\s*<action android:name="android.intent.action.SEND" />\s*<data android:mimeType="${NearbyShare.TYPE}" />\s*</intent>""").containsMatchIn(manifest))
    }

    @Test fun everyLanguageHasTheShareWording() {
        val keys = listOf("export_choice_title", "export_choice_body", "export_send_warning", "export_save_file", "export_send_with", "export_arrived_title",
            "export_arrived_body", "export_arrived_yes", "export_arrived_no", "export_sent_done", "export_sent_weak", "export_sent_not_counted")
        for (dir in listOf("values", "values-b+zh+Hans", "values-b+zh+Hant")) {
            val strings = File("src/main/res/$dir/strings_main.xml").readText()
            for (key in keys) assertTrue("$dir lacks $key", strings.contains("<string name=\"$key\">"))
            assertTrue(dir, Regex("""<string name="export_send_with">[^<]*%1\${'$'}s[^<]*</string>""").containsMatchIn(strings))
        }
    }
}
