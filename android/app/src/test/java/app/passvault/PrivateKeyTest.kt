package app.passvault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PrivateKeyTest {
    @Test fun validatesShape() {
        assertNotNull(PrivateKey.problem(""))
        assertNotNull(PrivateKey.problem("abc def ghi jkl mno pqr"))
        assertNotNull(PrivateKey.problem("short"))
        assertNull(PrivateKey.problem(" 0x" + "ab".repeat(32) + "\n"))
    }
    @Test fun detectsFormat() {
        assertEquals(R.string.seed_fmt_hex, PrivateKey.format("ab".repeat(32)).res)
        assertEquals(R.string.seed_fmt_wif, PrivateKey.format("5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ").res)
    }
    @Test fun recordExposesKey() {
        val r = VaultRecord(type = RecordType.seed, fields = listOf(VaultField(kind = FieldKind.password, label = PRIVATE_KEY_LABEL, value = "k".repeat(20))))
        assertEquals("k".repeat(20), r.privateKey); assertEquals(emptyList<String>(), r.seedWords)
    }
}
