package app.passvault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class GroupColorTest {
    @Test fun stableAndCaseInsensitive() {
        assertEquals(groupColorArgb("Work"), groupColorArgb(" work "))
        assertNotEquals(groupColorArgb("Work"), groupColorArgb("Family"))
        assertEquals(0xFF, groupColorArgb("Any") ushr 24)
    }
}
