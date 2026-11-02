package app.passvault

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class MainActivityLockInstrumentedTest {
    @Test fun screenOffLocksAVaultThatWasAlreadyInTheBackground() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as Application
        // Keep the QA activity visible even if the emulator's test PIN is still locked.
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
        try {
            val running = ActivityScenario.launch(MainActivity::class.java); scenario = running
            val deadline = SystemClock.uptimeMillis() + 5000
            var ready = false
            while (!ready && SystemClock.uptimeMillis() < deadline) {
                running.onActivity { ready = get(it, "Ready") as Boolean }
                if (!ready) Thread.sleep(10)
            }
            assertTrue("Vault must initialize", ready)
            lateinit var activity: MainActivity
            running.onActivity {
                activity = it
                set(it, "AutoLock", AutoLock::class.java, AutoLock.deviceLock)
                set(it, "BiometricEnabled", Boolean::class.javaPrimitiveType!!, false)
                set(it, "Records", List::class.java, listOf(VaultRecord(name = "Private entry")))
                set(it, "Unlocked", Boolean::class.javaPrimitiveType!!, true)
            }
            running.moveToState(Lifecycle.State.CREATED)
            instrumentation.runOnMainSync {
                assertEquals(true, get(activity, "Unlocked"))
                // Exercise the receiver while stopped; ACTION_SCREEN_OFF is a protected system broadcast.
                val receiver = MainActivity::class.java.getDeclaredField("screenOff").apply { isAccessible = true }.get(activity) as BroadcastReceiver
                receiver.onReceive(activity, Intent(Intent.ACTION_SCREEN_OFF))
                assertEquals(false, get(activity, "Unlocked"))
                assertEquals(emptyList<VaultRecord>(), get(activity, "Records"))
            }
            running.moveToState(Lifecycle.State.RESUMED)
            running.onActivity { assertEquals(false, get(it, "Unlocked")) }
        } finally { scenario?.close(); app.unregisterActivityLifecycleCallbacks(windows) }
    }

    private fun set(activity: MainActivity, name: String, type: Class<*>, value: Any) {
        MainActivity::class.java.getDeclaredMethod("set$name", type).apply { isAccessible = true }.invoke(activity, value)
    }
    private fun get(activity: MainActivity, name: String): Any? =
        MainActivity::class.java.getDeclaredMethod("get$name").apply { isAccessible = true }.invoke(activity)
}
