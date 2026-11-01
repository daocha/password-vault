package app.passvault

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.SemanticsNodeInteractionsProvider
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
private fun text(id: Int) = context.getString(id)
private fun code(name: String, favorite: Boolean = false, position: Int? = null) = VaultRecord(name = name, favorite = favorite, type = RecordType.totp,
    fields = listOf(VaultField(kind = FieldKind.password, label = TOTP_LABEL, value = "otpauth://totp/$name:me?secret=JBSWY3DPEHPK3PXP&issuer=$name")),
    legacy = position?.let { mapOf(TotpOrder.KEY to it.toString()) } ?: emptyMap())

/** The names, top to bottom as drawn: the semantics tree keeps composition order, which a moved lazy item does not follow. */
private fun SemanticsNodeInteractionsProvider.shownOrder(names: List<String>) = names.sortedBy { onNodeWithText(it).fetchSemanticsNode().positionInRoot.y }

/** The reorder screen on its own: what it shows, its accessibility actions, Save and Cancel, and dragging by the handle. */
class TotpReorderScreenInstrumentedTest {
    @get:Rule val rule = createComposeRule()
    private val codes = listOf(code("Alpha"), code("Beta"), code("Gamma"))
    private val names = codes.map { it.name }
    private var saved: List<String>? = null
    private var cancelled = false

    private fun show() = rule.setContent { TotpReorder(codes, onCancel = { cancelled = true }, onSave = { saved = it }) }
    private fun row(name: String): SemanticsNodeInteraction = rule.onNode(hasTestTag(REORDER_ROW) and hasAnyDescendant(hasText(name)))
    private fun actions(name: String) = row(name).fetchSemanticsNode().config.getOrNull(SemanticsActions.CustomActions).orEmpty()
    private fun act(name: String, label: Int) { val action = actions(name).first { it.label == text(label) }; rule.runOnIdle { action.action() } }
    private val save get() = rule.onNodeWithText(text(R.string.seed_save))

    @Test fun showsTheCodesInTheGivenOrderWithNothingToSave() {
        show()
        assertEquals(names, rule.shownOrder(names))
        save.assertIsNotEnabled()
        rule.onNodeWithText(text(R.string.totp_reorder_hint)).assertExists()
    }

    @Test fun screenReadersCanMoveEachCodeExceptPastTheEnds() {
        show()
        assertEquals(listOf(text(R.string.totp_move_down)), actions("Alpha").map { it.label })
        assertEquals(listOf(text(R.string.totp_move_up), text(R.string.totp_move_down)), actions("Beta").map { it.label })
        assertEquals(listOf(text(R.string.totp_move_up)), actions("Gamma").map { it.label })
    }

    @Test fun movedCodesAreSavedInTheirNewOrder() {
        show()
        act("Alpha", R.string.totp_move_down); act("Gamma", R.string.totp_move_up)
        assertEquals(listOf("Beta", "Gamma", "Alpha"), rule.shownOrder(names))
        save.assertIsEnabled().performClick()
        assertEquals(listOf("Beta", "Gamma", "Alpha").map { n -> codes.first { it.name == n }.id }, saved)
        assertFalse(cancelled)
    }

    @Test fun movingBackLeavesNothingToSave() {
        show()
        act("Beta", R.string.totp_move_up); save.assertIsEnabled()
        act("Beta", R.string.totp_move_down)
        assertEquals(names, rule.shownOrder(names)); save.assertIsNotEnabled()
    }

    @Test fun cancelDiscardsTheNewOrder() {
        show()
        act("Alpha", R.string.totp_move_down)
        rule.onNodeWithContentDescription(text(R.string.seed_discard)).performClick()
        assertTrue(cancelled); assertNull(saved)
    }

    @Test fun draggingTheHandleMovesTheCode() {
        show()
        val height = row("Alpha").fetchSemanticsNode().size.height.toFloat()
        // Down past the middle of the second row below: Alpha ends up last.
        rule.onNode(hasTestTag(REORDER_HANDLE) and hasAnyAncestorRow("Alpha")).performTouchInput {
            down(center); repeat(20) { moveBy(androidx.compose.ui.geometry.Offset(0f, height * 2.2f / 20)) }; up()
        }
        rule.waitForIdle()
        assertEquals(listOf("Beta", "Gamma", "Alpha"), rule.shownOrder(names))
        save.performClick()
        assertEquals(listOf("Beta", "Gamma", "Alpha").map { n -> codes.first { it.name == n }.id }, saved)
    }

    @Test fun draggingUpMovesTheCodeUp() {
        show()
        val height = row("Gamma").fetchSemanticsNode().size.height.toFloat()
        rule.onNode(hasTestTag(REORDER_HANDLE) and hasAnyAncestorRow("Gamma")).performTouchInput {
            down(center); repeat(20) { moveBy(androidx.compose.ui.geometry.Offset(0f, -height * 2.2f / 20)) }; up()
        }
        rule.waitForIdle()
        assertEquals(listOf("Gamma", "Alpha", "Beta"), rule.shownOrder(names))
    }

    @Test fun draggingARowAwayFromItsHandleDoesNotMoveIt() {
        show()
        val height = row("Alpha").fetchSemanticsNode().size.height.toFloat()
        // On the name, not the handle: this is a scroll, so the order stays and there is nothing to save.
        rule.onNodeWithText("Alpha").performTouchInput { down(center); repeat(20) { moveBy(androidx.compose.ui.geometry.Offset(0f, height * 2.2f / 20)) }; up() }
        rule.waitForIdle()
        assertEquals(names, rule.shownOrder(names)); save.assertIsNotEnabled()
    }

    @Test fun draggingPastTheBottomScrollsALongList() {
        val many = (1..40).map { code("Code %02d".format(it)) }
        var result: List<String>? = null
        rule.setContent { TotpReorder(many, onCancel = {}, onSave = { result = it }) }
        val height = rule.onNode(hasTestTag(REORDER_ROW) and hasAnyDescendant(hasText("Code 01"))).fetchSemanticsNode().size.height.toFloat()
        // Hold the first code still at the bottom of the screen: the list keeps scrolling and carries it far past the first screen.
        val handle = rule.onNode(hasTestTag(REORDER_HANDLE) and hasAnyAncestor(hasTestTag(REORDER_ROW) and hasAnyDescendant(hasText("Code 01"))))
        val startY = handle.fetchSemanticsNode().boundsInRoot.center.y
        val screen = rule.onRoot().fetchSemanticsNode().size.height
        // A held row asks for a frame every frame (to keep scrolling), so the clock is driven by hand until the finger lifts.
        rule.mainClock.autoAdvance = false
        handle.performTouchInput { down(center); repeat(20) { moveBy(androidx.compose.ui.geometry.Offset(0f, (screen - startY - height / 4) / 20)) } }
        rule.mainClock.advanceTimeBy(4_000)
        handle.performTouchInput { up() }
        rule.mainClock.advanceTimeBy(100); rule.mainClock.autoAdvance = true
        rule.waitForIdle()
        save.performClick()
        val moved = result!!.indexOf(many[0].id)
        assertTrue("Code 01 only reached position $moved", moved > 15)
        assertEquals(many.map { it.id }.filter { it != many[0].id }, result!!.filter { it != many[0].id }) // The others keep their order.
    }

    private fun hasAnyAncestorRow(name: String) = androidx.compose.ui.test.hasAnyAncestor(hasTestTag(REORDER_ROW) and hasAnyDescendant(hasText(name)))
}

/** The 2FA tab of the vault screen: it lists codes in the stored order and offers Reorder only when there is something to order. */
class TotpListOrderInstrumentedTest {
    @get:Rule val rule = createEmptyComposeRule()

    private fun <T> withVault(records: List<VaultRecord>, block: () -> T): T {
        val app = context.applicationContext as Application
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
            scenario.onActivity { activity ->
                set(activity, "Records", List::class.java, records)
                set(activity, "Tab", RecordType::class.java, RecordType.totp)
                set(activity, "Unlocked", Boolean::class.javaPrimitiveType!!, true)
            }
            rule.waitForIdle()
            return block()
        } finally { scenario.close(); app.unregisterActivityLifecycleCallbacks(windows) }
    }

    @Test fun listFollowsTheStoredOrderThenFavoritesThenName() {
        // Positions first (Zulu 0, Mike 1), then codes without one: favorite first, then by name.
        val records = listOf(code("Alpha"), code("Mike", position = 1), code("Bravo", favorite = true), code("Zulu", position = 0), VaultRecord(name = "A login"))
        withVault(records) {
            assertEquals(listOf("Zulu", "Mike", "Bravo", "Alpha"), rule.shownOrder(listOf("Alpha", "Mike", "Bravo", "Zulu")))
            rule.onNodeWithTag(REORDER_BUTTON).assertExists()
        }
    }

    @Test fun neverReorderedKeepsTheOldOrder() {
        withVault(listOf(code("Charlie"), code("Alpha"), code("Bravo", favorite = true))) {
            assertEquals(listOf("Bravo", "Alpha", "Charlie"), rule.shownOrder(listOf("Alpha", "Bravo", "Charlie")))
        }
    }

    @Test fun reorderOpensWithEveryCodeAndCancelReturns() {
        withVault(listOf(code("Alpha"), code("Bravo"), code("Charlie"))) {
            rule.onNodeWithTag(REORDER_BUTTON).performClick()
            rule.onNodeWithText(text(R.string.totp_reorder_title)).assertExists()
            assertEquals(3, rule.onAllNodes(hasTestTag(REORDER_ROW)).fetchSemanticsNodes().size)
            rule.onNodeWithContentDescription(text(R.string.seed_discard)).performClick()
            rule.onNodeWithText(text(R.string.totp_reorder_title)).assertDoesNotExist()
            rule.onNodeWithTag(REORDER_BUTTON).assertExists()
        }
    }

    @Test fun oneCodeHasNothingToReorder() {
        withVault(listOf(code("Alpha"))) { rule.onNodeWithTag(REORDER_BUTTON).assertDoesNotExist() }
    }

    private fun set(activity: MainActivity, name: String, type: Class<*>, value: Any) {
        MainActivity::class.java.getDeclaredMethod("set$name", type).apply { isAccessible = true }.invoke(activity, value)
    }
}
