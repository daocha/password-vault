package app.passvault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class EntrySplitTest {
    @Test fun phonesInLandscapeTabletsAndUnfoldedFoldablesSplit() {
        assertTrue("a phone in landscape", EntrySplit.isWide(915, 411))
        assertTrue("a small phone in landscape, beside its navigation bar", EntrySplit.isWide(592, 360))
        assertTrue("a tablet held upright", EntrySplit.isWide(800, 1280))
        assertTrue("an unfolded foldable", EntrySplit.isWide(673, 841))
        assertTrue("a tablet in landscape", EntrySplit.isWide(1280, 800))
    }

    @Test fun uprightPhonesAndSmallWindowsKeepTheFullScreenEntry() {
        assertFalse("a phone held upright", EntrySplit.isWide(411, 915))
        assertFalse("a folded phone", EntrySplit.isWide(360, 780))
        // Split screen on an upright phone can give a window wider than it is tall, but too small for two columns.
        assertFalse("half of an upright phone", EntrySplit.isWide(411, 400))
        assertFalse("a tiny landscape window", EntrySplit.isWide(540, 300))
    }

    @Test fun onlyAPhoneInLandscapeMovesTheTabsBesideTheList() {
        assertTrue("a phone in landscape", EntrySplit.tabsBeside(915, 411))
        assertTrue("a small phone in landscape", EntrySplit.tabsBeside(592, 360))
        assertFalse("a tablet in landscape has the height to keep them above the list", EntrySplit.tabsBeside(1280, 800))
        assertFalse("an unfolded foldable", EntrySplit.tabsBeside(673, 841))
        assertFalse("a phone held upright has no pane", EntrySplit.tabsBeside(411, 915))
        assertFalse("a short window too narrow to split", EntrySplit.tabsBeside(411, 400))
    }

    @Test fun theListTakesUnderHalfTheWidthWithinLimits() {
        assertEquals(280f, EntrySplit.listWidthDp(560f), 0f)
        assertEquals(.45f * 800, EntrySplit.listWidthDp(800f), .01f)
        assertEquals(420f, EntrySplit.listWidthDp(1280f), 0f)
        for (width in listOf(560f, 600f, 732f, 915f, 1280f)) assertTrue("the entry gets at least as much room as the list at $width", width - EntrySplit.listWidthDp(width) >= EntrySplit.listWidthDp(width))
        assertEquals("never wider than the window", 200f, EntrySplit.listWidthDp(200f), 0f)
    }

    @Test fun openDetailsFollowChangesMadeBesideThem() {
        val bank = VaultRecord(name = "Bank", fields = emptyList())
        val moved = bank.copy(group = "Family")
        assertSame("a group set from the list shows at once", moved, EntrySplit.refreshed(bank, editing = false, records = listOf(moved)))
        assertNull("deleted from the list: the details close", EntrySplit.refreshed(bank, editing = false, records = emptyList()))
        assertNull("nothing open stays closed", EntrySplit.refreshed(null, editing = false, records = listOf(bank)))
    }

    @Test fun anOpenEditorKeepsItsOwnCopy() {
        val draft = VaultRecord(name = "New", fields = emptyList())
        assertSame("a new entry is not in the vault yet", draft, EntrySplit.refreshed(draft, editing = true, records = emptyList()))
        val bank = VaultRecord(name = "Bank", fields = emptyList())
        assertSame(bank, EntrySplit.refreshed(bank, editing = true, records = listOf(bank.copy(name = "Changed"))))
    }

    @Test fun backClearsTheSelectionOnlyWhileTheListIsInFront() {
        assertTrue("no entry open", EntrySplit.listInFront(entryOpen = false, editing = false, split = false))
        assertTrue("details beside the list", EntrySplit.listInFront(entryOpen = true, editing = false, split = true))
        assertFalse("an editor beside the list comes first", EntrySplit.listInFront(entryOpen = true, editing = true, split = true))
        assertFalse("details over the list (a phone turned upright with entries still selected)", EntrySplit.listInFront(entryOpen = true, editing = false, split = false))
    }
}
