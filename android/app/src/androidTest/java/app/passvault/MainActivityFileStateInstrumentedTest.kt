package app.passvault

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class MainActivityFileStateInstrumentedTest {
    @Test fun recreationReleasesSecretsWhileTheOldWorkerStillOwnsItsOutput() {
        val records = listOf(FileKeys.record("private file key", Age.generateIdentity().encoded, "private note"))
        val ticket = FileJobs.shared.start()!!
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        // QA emulators keep a PIN and may remain locked. Change only this test's windows; no production lock-screen behavior changes.
        val windows = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, state: Bundle?) {
                if (activity is MainActivity) { activity.setShowWhenLocked(true); activity.setTurnScreenOn(true) }
            }
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        }
        app.registerActivityLifecycleCallbacks(windows)
        var scenario: ActivityScenario<MainActivity>? = null
        lateinit var old: MainActivity
        try {
            val running = ActivityScenario.launch(MainActivity::class.java); scenario = running
            // Recovery waits for the old output owner; the vault itself must still initialize while that provider is blocked.
            val deadline = android.os.SystemClock.uptimeMillis() + 5000
            var ready = false
            while (!ready && android.os.SystemClock.uptimeMillis() < deadline) {
                running.onActivity { ready = get(it, "Ready") as Boolean }
                if (!ready) Thread.sleep(10)
            }
            assertTrue("Pending file cleanup must not block vault initialization", ready)
            running.onActivity { activity ->
                old = activity
                set(activity, "Records", List::class.java, records)
                set(activity, "Unlocked", Boolean::class.javaPrimitiveType!!, true)
                set(activity, "Message", String::class.java, "private filename.txt")
                MainActivity::class.java.getDeclaredField("fileJob").apply { isAccessible = true }.set(activity, ticket)
                set(activity, "FileProgress", FileProgress::class.java, FileProgress(true, 1024, 2048))
            }
            // onStop deliberately skips locking during configuration changes. The old worker can still retain this activity.
            running.recreate()
            running.onActivity { replacement ->
                assertNotSame(old, replacement)
                assertEquals(emptyList<VaultRecord>(), get(old, "Records"))
                assertEquals(false, get(old, "Unlocked")); assertEquals("", get(old, "Message"))
                assertNull(get(old, "FileProgress"))
                assertTrue(ticket.cancelled)
                assertTrue(FileJobs.shared.running.value)
                assertNull("Recreation must not release an output whose cleanup is still running", FileJobs.shared.start())
            }
        } finally { FileJobs.shared.finish(ticket); scenario?.close(); app.unregisterActivityLifecycleCallbacks(windows) }
    }

    private fun set(activity: MainActivity, name: String, type: Class<*>, value: Any) {
        MainActivity::class.java.getDeclaredMethod("set$name", type).apply { isAccessible = true }.invoke(activity, value)
    }
    private fun get(activity: MainActivity, name: String): Any? =
        MainActivity::class.java.getDeclaredMethod("get$name").apply { isAccessible = true }.invoke(activity)
}
