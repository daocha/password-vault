package app.passvault

import androidx.compose.ui.platform.AccessibilityManager
import org.junit.Assert.assertEquals
import org.junit.Test

class MessageTimeoutTest {
    /** Stands in for the system: what it is asked, and what it answers. */
    private class FakeAccessibility(private val answer: (Long) -> Long) : AccessibilityManager {
        var asked: List<Any> = emptyList()
        override fun calculateRecommendedTimeoutMillis(originalTimeoutMillis: Long, containsIcons: Boolean, containsText: Boolean, containsControls: Boolean): Long {
            asked = listOf(originalTimeoutMillis, containsIcons, containsText, containsControls)
            return answer(originalTimeoutMillis)
        }
    }

    @Test fun messagesHideAfterSixSecondsByDefault() {
        assertEquals(6000L, messageTimeoutMillis(null, error = false))
        assertEquals(6000L, messageTimeoutMillis(FakeAccessibility { it }, error = true))
    }

    @Test fun theSystemDecidesForScreenReadersAndLongerTimeSettings() {
        // TalkBack on: Compose's manager answers Long.MAX_VALUE for content with controls, so the message waits for OK.
        val talkBack = FakeAccessibility { Long.MAX_VALUE }
        assertEquals(Long.MAX_VALUE, messageTimeoutMillis(talkBack, error = false))
        assertEquals(listOf<Any>(6000L, false, true, true), talkBack.asked)
        // "Time to take action" set to two minutes.
        assertEquals(120_000L, messageTimeoutMillis(FakeAccessibility { 120_000L }, error = true))
    }

    @Test fun errorsMentionTheirWarningIcon() {
        val manager = FakeAccessibility { it }
        messageTimeoutMillis(manager, error = true)
        assertEquals(listOf<Any>(6000L, true, true, true), manager.asked)
    }
}
