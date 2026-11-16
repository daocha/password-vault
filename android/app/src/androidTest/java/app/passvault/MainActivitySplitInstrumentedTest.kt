package app.passvault

import android.app.Activity
import android.app.Application
import android.content.pm.ActivityInfo
import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** The vault screen on a phone turned sideways: the open entry beside the list, and turning back and forth while editing. */
class MainActivitySplitInstrumentedTest {
    @get:Rule val rule = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun text(id: Int) = instrumentation.targetContext.getString(id)

    private fun withVault(records: List<VaultRecord>, block: (ActivityScenario<MainActivity>) -> Unit) {
        val app = instrumentation.targetContext.applicationContext as Application
        // QA emulators keep a PIN and may remain locked. Change only this test's windows; no production lock-screen behavior changes.
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
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            val deadline = SystemClock.uptimeMillis() + 5000
            var ready = false
            while (!ready && SystemClock.uptimeMillis() < deadline) {
                scenario.onActivity { ready = get(it, "Ready") as Boolean }
                if (!ready) Thread.sleep(10)
            }
            assertTrue("Vault must initialize", ready)
            scenario.onActivity { activity ->
                set(activity, "Records", List::class.java, records)
                // The backup reminder would push the rows below a small landscape screen's fold (and its dismiss button is also "Close").
                set(activity, "BackupSnoozedUntil", java.time.Instant::class.java, java.time.Instant.now().plusSeconds(3600))
                set(activity, "Unlocked", Boolean::class.javaPrimitiveType!!, true)
            }
            rule.waitForIdle()
            block(scenario)
        } finally {
            scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
            scenario.close(); app.unregisterActivityLifecycleCallbacks(windows)
        }
    }

    /** Turns the emulator and waits until the activity has taken in the new window size. */
    private fun turn(scenario: ActivityScenario<MainActivity>, landscape: Boolean) {
        scenario.onActivity { it.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
        rule.waitUntil(15_000) { var wide = !landscape; scenario.onActivity { wide = get(it, "WindowWide") as Boolean }; wide == landscape }
        rule.waitForIdle()
    }

    /** The details' close button in the pane beside the list. */
    private val paneClose get() = rule.onNode(hasContentDescription(text(R.string.main_close)) and hasAnyAncestor(hasTestTag(SPLIT_PANE)))
    private fun open(scenario: ActivityScenario<MainActivity>, name: String) {
        rule.onNodeWithText(name).performScrollTo().performClick()
        rule.waitForIdle()
        scenario.onActivity { assertEquals(name, (get(it, "Viewing") as VaultRecord?)?.name) }
    }
    private val nameField get() = rule.onNode(hasSetTextAction() and hasText(text(R.string.main_name)))

    @Test fun anEntryOpensBesideTheListAndKeepsUnsavedEditsWhenTurned() {
        withVault(listOf(VaultRecord(name = "Bank"))) { scenario ->
            turn(scenario, landscape = true)
            rule.onNodeWithText(text(R.string.main_no_entry_selected)).assertExists()
            // A phone in landscape: the tabs sit above the pane, and still switch the list.
            rule.onNode(hasTestTag(PANE_TABS)).assertExists()
            rule.onNode(hasText(text(R.string.main_seed_phrases)) and hasAnyAncestor(hasTestTag(SPLIT_LIST))).assertDoesNotExist()
            rule.onNode(hasText(text(R.string.main_seed_phrases)) and hasAnyAncestor(hasTestTag(PANE_TABS))).performClick()
            scenario.onActivity { assertEquals(RecordType.seed, get(it, "Tab")) }
            rule.onNode(hasText(text(R.string.main_passwords)) and hasAnyAncestor(hasTestTag(PANE_TABS))).performClick()
            scenario.onActivity { assertEquals(RecordType.login, get(it, "Tab")) }
            open(scenario, "Bank")
            rule.onNodeWithTag(SPLIT_PANE).assertExists()
            paneClose.assertExists()
            rule.onNodeWithContentDescription(text(R.string.main_settings)).assertExists() // The list is still there.

            rule.onNodeWithContentDescription(text(R.string.main_edit)).performClick()
            rule.onNodeWithTag(SPLIT_LIST_LOCKED).assertExists()
            nameField.performTextReplacement("Bank (joint)")

            turn(scenario, landscape = false)
            rule.onNodeWithTag(SPLIT_PANE).assertDoesNotExist()
            nameField.assertTextContains("Bank (joint)")
            turn(scenario, landscape = true)
            rule.onNodeWithTag(SPLIT_LIST_LOCKED).assertExists()
            nameField.assertTextContains("Bank (joint)")

            // Back closes the editor first, unsaved, and the list is usable again.
            scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            rule.waitForIdle()
            rule.onNodeWithTag(SPLIT_LIST_LOCKED).assertDoesNotExist()
            rule.onNode(hasSetTextAction()).assertDoesNotExist()
            scenario.onActivity { assertEquals(listOf("Bank"), (get(it, "Records") as List<*>).map { r -> (r as VaultRecord).name }) }

            // Details beside the list close before a whole-window screen opens from the list.
            rule.onNodeWithContentDescription(text(R.string.main_settings)).performClick()
            rule.waitForIdle()
            scenario.onActivity { assertEquals(null, get(it, "Viewing")) }
            scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            rule.waitForIdle()
            rule.onNodeWithText(text(R.string.main_no_entry_selected)).assertExists()
        }
    }

    @Test fun turningUprightShowsTheOpenDetailsFullScreen() {
        withVault(listOf(VaultRecord(name = "Bank"))) { scenario ->
            turn(scenario, landscape = true)
            open(scenario, "Bank")
            paneClose.assertExists()
            turn(scenario, landscape = false)
            rule.onNodeWithTag(SPLIT_PANE).assertDoesNotExist()
            rule.onNodeWithTag(PANE_TABS).assertDoesNotExist()
            rule.onNodeWithContentDescription(text(R.string.main_back)).assertExists()
            rule.onNodeWithContentDescription(text(R.string.main_settings)).assertDoesNotExist()
            rule.onNodeWithContentDescription(text(R.string.main_back)).performClick()
            rule.onNodeWithContentDescription(text(R.string.main_settings)).assertExists()
            rule.onNodeWithText(text(R.string.main_seed_phrases)).assertExists() // Upright, the tabs are back above the list.
        }
    }

    private fun set(activity: MainActivity, name: String, type: Class<*>, value: Any) {
        MainActivity::class.java.getDeclaredMethod("set$name", type).apply { isAccessible = true }.invoke(activity, value)
    }
    private fun get(activity: MainActivity, name: String): Any? =
        MainActivity::class.java.getDeclaredMethod("get$name").apply { isAccessible = true }.invoke(activity)
}
