package app.passvault

import androidx.test.core.app.ActivityScenario
import org.junit.Assert.*
import org.junit.Test

class MainActivityFileStateInstrumentedTest {
    @Test fun recreationReleasesSecretsWhileTheOldWorkerStillOwnsItsOutput() {
        val records = listOf(FileKeys.record("private file key", Age.generateIdentity().encoded, "private note"))
        val ticket = FileJobs.shared.start()!!
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var old: MainActivity
        try {
            scenario.onActivity { activity ->
                old = activity
                set(activity, "Records", List::class.java, records)
                set(activity, "Unlocked", Boolean::class.javaPrimitiveType!!, true)
                set(activity, "Message", String::class.java, "private filename.txt")
                MainActivity::class.java.getDeclaredField("fileJob").apply { isAccessible = true }.set(activity, ticket)
                set(activity, "FileProgress", FileProgress::class.java, FileProgress(true, 1024, 2048))
            }
            // onStop deliberately skips locking during configuration changes. The old worker can still retain this activity.
            scenario.recreate()
            scenario.onActivity { replacement ->
                assertNotSame(old, replacement)
                assertEquals(emptyList<VaultRecord>(), get(old, "Records"))
                assertEquals(false, get(old, "Unlocked")); assertEquals("", get(old, "Message"))
                assertNull(get(old, "FileProgress"))
                assertTrue(ticket.cancelled)
                assertTrue(FileJobs.shared.running.value)
                assertNull("Recreation must not release an output whose cleanup is still running", FileJobs.shared.start())
            }
        } finally { FileJobs.shared.finish(ticket); scenario.close() }
    }

    private fun set(activity: MainActivity, name: String, type: Class<*>, value: Any) {
        MainActivity::class.java.getDeclaredMethod("set$name", type).apply { isAccessible = true }.invoke(activity, value)
    }
    private fun get(activity: MainActivity, name: String): Any? =
        MainActivity::class.java.getDeclaredMethod("get$name").apply { isAccessible = true }.invoke(activity)
}
