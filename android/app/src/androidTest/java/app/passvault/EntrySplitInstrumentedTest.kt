package app.passvault

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** The list beside the open entry: what each side shows, the locked list beside an editor, and turning the phone. */
class EntrySplitInstrumentedTest {
    @get:Rule val rule = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private var wide by mutableStateOf(true)
    private var locked by mutableStateOf(false)
    private var open by mutableStateOf(true)
    private var listTaps = 0

    /**
     * As MainActivity uses it: one call, whichever of the list and the entry are shown. Drawn at least [WIDTH_DP] wide,
     * whatever the test device's screen (CI's emulator is a small phone held upright), by scaling the density down.
     */
    private fun show() = rule.setContent {
        val density = LocalDensity.current
        val widthPx = LocalConfiguration.current.screenWidthDp * density.density
        CompositionLocalProvider(LocalDensity provides Density(minOf(density.density, widthPx / WIDTH_DP), density.fontScale)) { content() }
    }
    @androidx.compose.runtime.Composable private fun content() {
        EntrySplitLayout(showList = wide || !open, showPane = wide || open, listLocked = locked,
            list = { Column(Modifier.fillMaxSize().testTag("list")) { Button(onClick = { listTaps++ }) { Text("Row") } } },
            pane = {
                if (open) {
                    // A draft as the editors keep it: plain remembered state, gone if the editor left the composition or moved.
                    var draft by remember { mutableStateOf("") }; var count by remember { mutableIntStateOf(0) }
                    Column {
                        TextField(draft, { draft = it }, Modifier.testTag("draft")); Button(onClick = { count++ }) { Text("Count $count") }
                        // Stands in for the QR scanner's camera preview, which must not be detached and attached again.
                        AndroidView({ android.view.View(it).apply { addOnAttachStateChangeListener(object : android.view.View.OnAttachStateChangeListener {
                            override fun onViewAttachedToWindow(v: android.view.View) { attachCount++ }
                            override fun onViewDetachedFromWindow(v: android.view.View) {}
                        }) } }, Modifier.testTag("camera"))
                    }
                } else NoEntrySelected()
            })
    }
    private var attachCount = 0
    private companion object { const val WIDTH_DP = 720f }

    @Test fun showsTheListAndTheEntrySideBySide() {
        show()
        rule.onNodeWithText("Row").assertIsDisplayed()
        rule.onNodeWithTag("draft").assertIsDisplayed()
        val list = rule.onNodeWithTag(SPLIT_LIST).fetchSemanticsNode().boundsInRoot
        val pane = rule.onNodeWithTag(SPLIT_PANE).fetchSemanticsNode().boundsInRoot
        assertTrue("the entry is to the right of the list", pane.left >= list.right)
        assertTrue("the entry gets at least as much room as the list", pane.width >= list.width)
        rule.onNodeWithText("Row").performClick()
        assertEquals("the list stays usable beside the details", 1, listTaps)
    }

    @Test fun showsAHintUntilAnEntryIsOpen() {
        open = false; show()
        rule.onNodeWithText(context.getString(R.string.main_no_entry_selected)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.main_no_entry_selected_body)).assertIsDisplayed()
    }

    @Test fun theListIsOutOfReachBesideAnEditor() {
        locked = true; show()
        rule.onNodeWithTag(SPLIT_LIST_LOCKED).assertIsDisplayed()
        // Hidden from TalkBack, and a tap where the row is drawn does not reach it.
        assertEquals(0, rule.onAllNodesWithText("Row").size)
        rule.onNodeWithTag(SPLIT_LIST_LOCKED).performTouchInput { click(center); click(androidx.compose.ui.geometry.Offset(centerX, top + 40f)) }
        rule.waitForIdle()
        assertEquals(0, listTaps)
        // The editor beside it still works.
        rule.onNodeWithText("Count 0").performClick()
        rule.onNodeWithText("Count 1").assertIsDisplayed()

        locked = false
        rule.onNodeWithText("Row").performClick()
        assertEquals("unlocked once the editor closes", 1, listTaps)
    }

    @Test fun turningThePhoneKeepsUnsavedEditsAndTheCameraView() {
        locked = true; show()
        rule.onNodeWithTag("draft").performTextInput("typed")
        rule.onNodeWithText("Count 0").performClick()
        assertEquals(1, attachCount)
        wide = false; rule.waitForIdle()
        rule.onNodeWithTag(SPLIT_PANE).assertDoesNotExist()
        rule.onNodeWithTag(SPLIT_LIST_LOCKED).assertDoesNotExist()
        rule.onNodeWithText("Row").assertDoesNotExist()
        rule.onNodeWithTag("draft").assertTextContains("typed")
        rule.onNodeWithText("Count 1").assertIsDisplayed()
        wide = true; rule.waitForIdle()
        rule.onNodeWithTag(SPLIT_PANE).assertIsDisplayed()
        rule.onNodeWithTag(SPLIT_LIST_LOCKED).assertIsDisplayed()
        rule.onNodeWithTag("draft").assertTextContains("typed")
        rule.onNodeWithText("Count 1").assertIsDisplayed()
        assertEquals("the camera view stays attached", 1, attachCount)
    }

    @Test fun turningThePhoneKeepsTheList() {
        open = false; show()
        rule.onNodeWithText("Row").performClick()
        wide = false; rule.waitForIdle()
        rule.onNodeWithText(context.getString(R.string.main_no_entry_selected)).assertDoesNotExist()
        rule.onNodeWithText("Row").assertIsDisplayed().performClick()
        assertEquals(2, listTaps)
        val narrow = rule.onNodeWithTag("list").fetchSemanticsNode().boundsInRoot.width
        wide = true; rule.waitForIdle()
        assertTrue("the list shares the window", rule.onNodeWithTag("list").fetchSemanticsNode().boundsInRoot.width < narrow)
        rule.onNodeWithText(context.getString(R.string.main_no_entry_selected)).assertIsDisplayed()
    }

    private fun androidx.compose.ui.test.SemanticsNodeInteractionsProvider.onAllNodesWithText(text: String) =
        onAllNodes(androidx.compose.ui.test.hasText(text)).fetchSemanticsNodes()
}
