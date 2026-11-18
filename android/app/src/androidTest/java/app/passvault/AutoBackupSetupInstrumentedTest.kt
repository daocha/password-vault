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
            Thread.sleep(1100) // a new second, so a new name
            instrumentation.runOnMainSync { call(activity, "autoBackup", Boolean::class.javaPrimitiveType!! to true, Boolean::class.javaPrimitiveType!! to true) }
            waitFor("Back up now is confirmed in a dialog") { notice() != null }
            assertTrue(saved(notice()))
            assertEquals(2, target.listFiles()!!.size)
            assertNotNull("it counts for the backup reminder", BackupStatus(context.getSharedPreferences("settings", Activity.MODE_PRIVATE)).lastBackup)
        } finally {
            // The system save picker opened by the set-up; the emulator's lock screen can keep Back from reaching it.
            for (pkg in listOf("com.google.android.documentsui", "com.android.documentsui")) instrumentation.uiAutomation.executeShellCommand("am force-stop $pkg").close()
            scenario?.close(); app.unregisterActivityLifecycleCallbacks(windows)
        }
    }
}
