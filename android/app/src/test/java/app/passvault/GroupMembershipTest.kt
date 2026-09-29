package app.passvault

import org.junit.Assert.assertEquals
import org.junit.Test

class GroupMembershipTest {
    @Test fun allSomeNone() {
        assertEquals(true, groupMembership(listOf("A", "a "), "A"))
        assertEquals(null, groupMembership(listOf("A", "B", "A"), "A"))
        assertEquals(false, groupMembership(listOf("B", ""), "A"))
    }
}
