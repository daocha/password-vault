package app.passvault

import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** age encryption through ContentResolver streams on Android's runtime (BouncyCastle's ML-KEM and ChaCha20 on ART, not the JVM). */
class FileCryptInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(context.cacheDir, "filecrypt-test").apply { mkdirs() }
    @After fun clean() { directory.deleteRecursively() }

    @Test fun encryptsAndDecryptsLargeFiles() {
        val identity = Age.parseIdentity(Age.generateIdentity().encoded)
        val plain = File(directory, "plain.bin").apply { writeBytes(ByteArray(5 * Age.CHUNK + 123) { (it * 13).toByte() }) }
        val sealed = File(directory, "plain.bin.age"); val opened = File(directory, "opened.bin")
        var read = 0L
        FileCrypt.encrypt(context.contentResolver, Uri.fromFile(plain), Uri.fromFile(sealed), identity.recipient, { false }) { read = it }
        assertEquals(plain.length(), read)
        assertTrue(String(sealed.readBytes().copyOf(21)) == "age-encryption.org/v1")
        FileCrypt.check(context.contentResolver, Uri.fromFile(sealed), listOf(identity))
        FileCrypt.decrypt(context.contentResolver, Uri.fromFile(sealed), Uri.fromFile(opened), listOf(identity), { false }) {}
        assertArrayEquals(plain.readBytes(), opened.readBytes())
    }

    @Test fun failedOrCancelledOutputIsEmptied() {
        val identity = Age.generateIdentity()
        val plain = File(directory, "plain.bin").apply { writeBytes(ByteArray(3 * Age.CHUNK) { it.toByte() }) }
        val sealed = File(directory, "sealed.age")
        FileCrypt.encrypt(context.contentResolver, Uri.fromFile(plain), Uri.fromFile(sealed), identity.recipient, { false }) {}
        // Damage the last chunk: the first chunks decrypt and are written before the damage is found.
        val damaged = File(directory, "damaged.age").apply { writeBytes(sealed.readBytes().also { it[it.size - 5] = (it[it.size - 5].toInt() xor 1).toByte() }) }
        val out = File(directory, "out.bin")
        val e = assertThrows(AgeException::class.java) { FileCrypt.decrypt(context.contentResolver, Uri.fromFile(damaged), Uri.fromFile(out), listOf(identity), { false }) {} }
        assertEquals(AgeException.Kind.payload, e.kind)
        assertTrue("no plaintext left behind", !out.exists() || out.length() == 0L)
        val cancelled = File(directory, "cancelled.bin")
        assertThrows(FileCrypt.Cancelled::class.java) { FileCrypt.decrypt(context.contentResolver, Uri.fromFile(sealed), Uri.fromFile(cancelled), listOf(identity), { true }) {} }
        assertTrue(!cancelled.exists() || cancelled.length() == 0L)
        assertEquals(AgeException.Kind.noMatch, assertThrows(AgeException::class.java) { FileCrypt.check(context.contentResolver, Uri.fromFile(sealed), listOf(Age.generateIdentity())) }.kind)
    }
}
