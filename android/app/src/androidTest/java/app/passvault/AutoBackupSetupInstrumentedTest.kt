package app.passvault

import android.app.Activity
import android.app.Application
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.KeyStore
import java.time.Instant

/**
 * Setting up automatic backup through the screen's own code, as the Settings buttons do: the password check and key sealing run through
 * the activity's work queue, and the key it keeps for the picker's answer must still open afterwards (a cleanup once wiped it, so every
 * set-up looked like a changed password).
 */
class AutoBackupSetupInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val password = "A lengthy test passphrase 1!"
    private val target = File(context.cacheDir, "auto-backup-setup-test")

    private fun wipe() {
        File(context.noBackupFilesDir, "passvault").deleteRecursively()
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.let { ks -> java.util.Collections.list(ks.aliases()).filter { it.startsWith("passvault-") }.forEach(ks::deleteEntry) }
        AutoBackupSettings(context.getSharedPreferences("settings", Activity.MODE_PRIVATE)).clear()
        BackupStatus(context.getSharedPreferences("settings", Activity.MODE_PRIVATE)).clear()
        target.deleteRecursively()
    }
    @Before fun setUp() = wipe()
    @After fun tearDown() = wipe()

    private fun waitFor(what: String, timeout: Long = 30_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeout
        while (!condition() && SystemClock.uptimeMillis() < deadline) Thread.sleep(20)
        assertTrue(what, condition())
    }
    private fun call(activity: MainActivity, name: String, vararg args: Pair<Class<*>, Any>) {
        MainActivity::class.java.getDeclaredMethod(name, *args.map { it.first }.toTypedArray()).apply { isAccessible = true }.invoke(activity, *args.map { it.second }.toTypedArray())
    }
    private fun field(activity: MainActivity, name: String): Any? = MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }.get(activity)
    private fun getter(activity: MainActivity, name: String): Any? = MainActivity::class.java.getDeclaredMethod("get$name").apply { isAccessible = true }.invoke(activity)

    @Test fun settingUpKeepsAWorkingKeyShowsBackUpNowAndSavesAtOnce() {
        VaultEngine(ProtectedStorage(context)).apply { create(password); save(listOf(VaultRecord(name = "Bank"))); lock() }
        val app = context.applicationContext as Application
        val windows = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, state: Bundle?) { if (activity is MainActivity) { activity.setShowWhenLocked(true); activity.setTurnScreenOn(true) } }
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        }
        app.registerActivityLifecycleCallbacks(windows)
        var scenario: ActivityScenario<MainActivity>? = null
        try {
            val running = ActivityScenario.launch(MainActivity::class.java); scenario = running
            lateinit var activity: MainActivity
            running.onActivity { activity = it }
            waitFor("vault must initialize") { var ready = false; instrumentation.runOnMainSync { ready = getter(activity, "Ready") as Boolean }; ready }
            val engine = field(activity, "engine") as VaultEngine
            val records = engine.unlock(password)
            instrumentation.runOnMainSync {
                MainActivity::class.java.getDeclaredMethod("setRecords", List::class.java).apply { isAccessible = true }.invoke(activity, records)
                MainActivity::class.java.getDeclaredMethod("setUnlocked", Boolean::class.javaPrimitiveType).apply { isAccessible = true }.invoke(activity, true)
                // Unlock timing stays available in Settings without replacing the current status message.
                val message = getter(activity, "Message")
                call(activity, "recordUnlockTiming", Long::class.javaPrimitiveType!! to SystemClock.elapsedRealtime())
                assertTrue((getter(activity, "UnlockSummary") as String).isNotEmpty())
                assertEquals(message, getter(activity, "Message"))
                // What the "Choose a folder" button runs: a counted password check and the sealed key, then the folder picker.
                call(activity, "setUpAutoBackup", String::class.java to password)
            }
            var pending: ByteArray? = null
            waitFor("the password check finishes and the key waits for the picker") {
                var done = false
                instrumentation.runOnMainSync { pending = field(activity, "pendingAutoSetup") as ByteArray?; done = !(getter(activity, "Busy") as Boolean) && pending != null }
                done
            }
            val key = pending!!.copyOf()
            assertFalse("the kept key must not be wiped", key.all { it == 0.toByte() })
            assertTrue("the kept key opens with this vault's data key", engine.exportAutomatic(key, null) is VaultEngine.Automatic.Ready)
            waitFor("the folder picker opens") { running.state == androidx.lifecycle.Lifecycle.State.CREATED }
            // The vault stays open while the picker is up (a bounded grace period).
            instrumentation.runOnMainSync { assertEquals(true, getter(activity, "Unlocked")) }

            // The picker's answer, minus the persisted grant (a plain test folder needs none): turn on, show the panel, back up at once.
            target.mkdirs()
            instrumentation.runOnMainSync {
                call(activity, "turnOnAutoBackup", String::class.java to Uri.fromFile(target).toString(), String::class.java to target.name, ByteArray::class.java to key)
                assertEquals("AutoBackup", getter(activity, "SettingsDialog")?.javaClass?.simpleName)
            }
            val settings = AutoBackupSettings(context.getSharedPreferences("settings", Activity.MODE_PRIVATE))
            fun notice(): Any? { var value: Any? = null; instrumentation.runOnMainSync { value = getter(activity, "AutoBackupNotice") }; return value }
            fun saved(value: Any?) = value!!.javaClass.getDeclaredMethod("getSaved").apply { isAccessible = true }.invoke(value) as Boolean
            waitFor("the first automatic backup is saved and confirmed in a dialog") { settings.lastAutomatic != null && notice() != null }
            assertTrue(saved(notice()))
            assertNull(settings.problem)
            val files = target.listFiles()!!.toList()
            assertEquals(1, files.size)
            assertEquals(listOf("Bank"), VaultCrypto.importBackup(files.single().readBytes(), password).map { it.name })

            // Back up now: another file, confirmed again; the first one stays.
            instrumentation.runOnMainSync { MainActivity::class.java.getDeclaredMethod("setAutoBackupNotice", Class.forName("app.passvault.MainActivity\$AutoBackupNotice")).apply { isAccessible = true }.invoke(activity, null) }
            instrumentation.runOnMainSync { call(activity, "autoBackup", Boolean::class.javaPrimitiveType!! to true, Boolean::class.javaPrimitiveType!! to true) }
            waitFor("Back up now is confirmed in a dialog") { notice() != null }
            assertTrue(saved(notice()))
            assertEquals(2, target.listFiles()!!.size)
            assertNotNull("it counts for the backup reminder", BackupStatus(context.getSharedPreferences("settings", Activity.MODE_PRIVATE)).lastBackup)

            assertEquals(AutoBackupFrequency.instant, settings.frequency)
            val initialDigest = settings.lastDigest!!
            val added = VaultRecord(name = "Mail")
            instrumentation.runOnMainSync {
                call(activity, "saveRecord", VaultRecord::class.java to added, Function0::class.java to {})
            }
            waitFor("instant backs up a saved change without locking or leaving") { target.listFiles()!!.size == 3 && settings.lastDigest?.contentEquals(initialDigest) == false }
            val last = settings.lastAutomatic!!
            instrumentation.runOnMainSync { call(activity, "setAutoBackupFrequency", AutoBackupFrequency::class.java to AutoBackupFrequency.daily) }
            val deferred = VaultRecord(name = "Archive")
            instrumentation.runOnMainSync { call(activity, "saveRecord", VaultRecord::class.java to deferred, Function0::class.java to {}) }
            waitFor("the deferred edit finishes") { var done = false; instrumentation.runOnMainSync { done = getter(activity, "Busy") == false }; done }
            assertEquals("daily waits for the interval", 3, target.listFiles()!!.size)
            assertEquals(last, settings.lastAutomatic)
            settings.succeeded(settings.lastDigest!!, Instant.now().minusSeconds(86400).plusMillis(300))
            instrumentation.runOnMainSync { call(activity, "setAutoBackupFrequency", AutoBackupFrequency::class.java to AutoBackupFrequency.daily) }
            waitFor("the daily timer backs up changed contents at its boundary") { target.listFiles()!!.size == 4 && settings.lastAutomatic!!.isAfter(last) }
            assertTrue("a backup includes the deferred edit", target.listFiles()!!.any { file -> VaultCrypto.importBackup(file.readBytes(), password).any { it.name == "Archive" } })
            instrumentation.runOnMainSync {
                MainActivity::class.java.getDeclaredMethod("setAutoBackupNotice", Class.forName("app.passvault.MainActivity\$AutoBackupNotice")).apply { isAccessible = true }.invoke(activity, null)
                call(activity, "autoBackup", Boolean::class.javaPrimitiveType!! to true, Boolean::class.javaPrimitiveType!! to true)
            }
            waitFor("Back up now bypasses the daily interval") { notice() != null }
            assertTrue(saved(notice()))
            assertEquals(5, target.listFiles()!!.size)

            // Settings → Last encrypted backup: with automatic backup on, the newest backups in its folder instead of the export dialog.
            File(target, "holiday.jpg").writeBytes(byteArrayOf(9))
            repeat(2) { AutoBackupFiles.writeToFolder(AutoBackupFiles.folder(context.contentResolver, Uri.fromFile(target)), byteArrayOf(1), Instant.parse("2020-01-01T00:00:00Z")) }
            fun recent(): Any? { var value: Any? = null; instrumentation.runOnMainSync { value = getter(activity, "RecentBackups") }; return value }
            instrumentation.runOnMainSync { call(activity, "showRecentBackups") }
            waitFor("the newest backups are listed") { recent() != null }
            @Suppress("UNCHECKED_CAST") val listed = recent()!!.javaClass.getDeclaredMethod("getNames").apply { isAccessible = true }.invoke(recent()) as List<String>
            val newestFive = target.list()!!.filter { it.startsWith("passvault_auto_") }.sortedDescending().take(5)
            assertEquals(newestFive, listed)
            assertTrue("the 2020 backups are older than the five shown", listed.none { it.contains("2020-01-01") })
            instrumentation.runOnMainSync { MainActivity::class.java.getDeclaredMethod("setRecentBackups", Class.forName("app.passvault.MainActivity\$RecentBackups")).apply { isAccessible = true }.invoke(activity, null) }
            // A folder PassVault can no longer open is an error message, not a list.
            target.deleteRecursively()
            instrumentation.runOnMainSync { call(activity, "showRecentBackups") }
            waitFor("an unreadable folder is reported") { var shown = ""; instrumentation.runOnMainSync { shown = getter(activity, "Message") as String }; shown == context.getString(R.string.auto_backup_recent_no_access, target.name) }
            assertNull(recent())
        } finally {
            // The system save picker opened by the set-up; the emulator's lock screen can keep Back from reaching it.
            for (pkg in listOf("com.google.android.documentsui", "com.android.documentsui")) instrumentation.uiAutomation.executeShellCommand("am force-stop $pkg").close()
            scenario?.close(); app.unregisterActivityLifecycleCallbacks(windows)
        }
    }
}
