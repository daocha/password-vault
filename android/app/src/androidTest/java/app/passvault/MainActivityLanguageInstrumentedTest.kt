package app.passvault

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class MainActivityLanguageInstrumentedTest {
    /** Changing the language redraws in place: recreating the activity would lock the vault and send the user to the login screen. */
    @Test fun changingTheLanguageKeepsTheVaultUnlockedAndTheSameActivity() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as Application
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
        val settings = app.getSharedPreferences("settings", android.content.Context.MODE_PRIVATE)
        val savedLanguage = settings.getString("language", null)
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
                set(it, "BiometricEnabled", Boolean::class.javaPrimitiveType!!, false)
                set(it, "Records", List::class.java, listOf(VaultRecord(name = "Private entry")))
                set(it, "Unlocked", Boolean::class.javaPrimitiveType!!, true)
            }
            val system = app.getString(R.string.main_settings)
            for ((tag, expected) in listOf("zh-Hans" to "设置", "zh-Hant" to "設定", "" to system)) {
                instrumentation.runOnMainSync {
                    set(activity, "Language", String::class.java, tag)
                    settings.edit().putString("language", tag).commit()
                    MainActivity::class.java.getDeclaredMethod("applyLanguage").apply { isAccessible = true }.invoke(activity)
                }
                instrumentation.waitForIdleSync()
                assertEquals("'$tag' reaches getString", expected, activity.getString(R.string.main_settings))
                assertEquals("'$tag' reaches resources", expected, activity.resources.getString(R.string.main_settings))
                running.onActivity {
                    assertSame("The activity must not be recreated", activity, it)
                    assertEquals("The vault must stay unlocked", true, get(it, "Unlocked"))
                    assertEquals(1, (get(it, "Records") as List<*>).size)
                }
            }
        } finally {
            settings.edit().apply { if (savedLanguage == null) remove("language") else putString("language", savedLanguage) }.commit()
            scenario?.close(); app.unregisterActivityLifecycleCallbacks(windows)
        }
    }

    private fun set(activity: MainActivity, name: String, type: Class<*>, value: Any) {
        MainActivity::class.java.getDeclaredMethod("set$name", type).apply { isAccessible = true }.invoke(activity, value)
    }
    private fun get(activity: MainActivity, name: String): Any? =
        MainActivity::class.java.getDeclaredMethod("get$name").apply { isAccessible = true }.invoke(activity)
}
