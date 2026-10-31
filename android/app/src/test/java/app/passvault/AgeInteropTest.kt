package app.passvault

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * Interoperability with the official age tools (filippo.io/age, `age` and `age-keygen`), in both directions and for both key types.
 * The age test kit (AgeTest) only checks decryption, so this is what shows that files PassVault encrypts open on a computer.
 *
 * Needs the official tools in AGE_BIN_DIR. CI installs a pinned version and sets AGE_INTEROP_REQUIRED, so there the test fails instead
 * of skipping when they are missing; elsewhere it is skipped.
 */
class AgeInteropTest {
    @get:Rule val folder = TemporaryFolder()
    private val bin = System.getenv("AGE_BIN_DIR")?.takeIf { it.isNotBlank() }
    // Empty, one byte, and both sides of the 64 KiB chunk boundary (a full last chunk is a special case in the format).
    private val sizes = listOf(0, 1, Age.CHUNK - 1, Age.CHUNK, Age.CHUNK + 1, 3 * Age.CHUNK + 5)

    @Before fun officialTools() {
        if (System.getenv("AGE_INTEROP_REQUIRED") == "1") assertNotNull("AGE_BIN_DIR must point at the official age tools", bin)
        assumeTrue("The official age tools are not installed; CI runs this test.", bin != null)
    }

    private fun tool(vararg args: String): String {
        val process = ProcessBuilder(listOf(File(bin!!, args[0]).path) + args.drop(1)).start()
        val out = process.inputStream.readBytes(); val err = process.errorStream.readBytes()
        assertTrue("${args.joinToString(" ")} timed out", process.waitFor(60, TimeUnit.SECONDS))
        assertEquals("${args.joinToString(" ")}: ${String(err)}", 0, process.exitValue())
        return String(out)
    }
    private fun payload(size: Int) = Random(size).nextBytes(size)
    private fun file(name: String, bytes: ByteArray) = folder.newFile(name).apply { writeBytes(bytes) }
    private fun keyFile(name: String, identity: String) = file(name, "$identity\n".toByteArray())
    private fun passVaultEncrypt(plain: ByteArray, recipient: Age.Recipient) =
        ByteArrayOutputStream().also { Age.encrypt(ByteArrayInputStream(plain), it, listOf(recipient)) }.toByteArray()
    private fun passVaultDecrypt(sealed: ByteArray, identity: Age.Identity) =
        ByteArrayOutputStream().also { Age.decrypt(ByteArrayInputStream(sealed), it, listOf(identity)) }.toByteArray()
    /** A key made by age-keygen: its secret, read the way a user would paste it into PassVault. */
    private fun officialKey(postQuantum: Boolean): String {
        val path = File(folder.root, "official-${if (postQuantum) "pq" else "x25519"}.txt")
        if (postQuantum) tool("age-keygen", "-pq", "-o", path.path) else tool("age-keygen", "-o", path.path)
        return path.readLines().single { it.startsWith("AGE-SECRET-KEY-") }
    }

    @Test fun theOfficialToolsAreTheVersionPassVaultDocuments() {
        // PassVault's keys are post-quantum, which age supports from 1.3.0; the docs and the app say so.
        val version = tool("age", "--version").trim()
        assertTrue("age $version is older than 1.3.0", Regex("""v?1\.(\d+)\.""").find(version)!!.groupValues[1].toInt() >= 3)
    }

    @Test fun filesPassVaultEncryptsOpenWithOfficialAge() {
        // PassVault's own key type (as made by "Create key"), and a classic key imported from age-keygen.
        val keys = listOf(Age.generateIdentity().encoded, officialKey(postQuantum = false))
        for ((k, secret) in keys.withIndex()) {
            val identity = Age.parseIdentity(secret); val keyFile = keyFile("key$k.txt", secret)
            assertEquals("PassVault and age-keygen derive the same public key", identity.recipient.encoded, tool("age-keygen", "-y", keyFile.path).trim())
            for (size in sizes) {
                val plain = payload(size)
                val sealed = file("pv-$k-$size.age", passVaultEncrypt(plain, identity.recipient))
                val opened = File(folder.root, "pv-$k-$size.out")
                tool("age", "-d", "-i", keyFile.path, "-o", opened.path, sealed.path)
                assertArrayEquals("key $k, $size bytes", plain, opened.readBytes())
            }
        }
    }

    @Test fun filesOfficialAgeEncryptsOpenInPassVault() {
        // Keys from age-keygen (both types) and PassVault's own key, with binary and ASCII-armored (-a) files.
        val keys = listOf(officialKey(postQuantum = true), officialKey(postQuantum = false), Age.generateIdentity().encoded)
        for ((k, secret) in keys.withIndex()) {
            val identity = Age.parseIdentity(secret)
            for (size in sizes) for (armor in listOf(false, true)) {
                val plain = payload(size); val input = file("in-$k-$size-$armor", plain)
                val sealed = File(folder.root, "age-$k-$size-$armor.age")
                tool("age", *(if (armor) arrayOf("-a") else emptyArray()), "-r", identity.recipient.encoded, "-o", sealed.path, input.path)
                assertArrayEquals("key $k, $size bytes, armor $armor", plain, passVaultDecrypt(sealed.readBytes(), identity))
            }
        }
    }

    @Test fun aFileForSeveralRecipientsOpensWithEachKey() {
        // age encrypts one file to several post-quantum keys; PassVault, holding any one of them, opens it, and PassVault's header
        // check finds its key among the others.
        val mine = Age.generateIdentity(); val other = Age.parseIdentity(officialKey(postQuantum = true))
        val plain = payload(Age.CHUNK + 7); val input = file("multi.in", plain); val sealed = File(folder.root, "multi.age")
        tool("age", "-r", other.recipient.encoded, "-r", mine.recipient.encoded, "-o", sealed.path, input.path)
        Age.checkHeader(ByteArrayInputStream(sealed.readBytes()), listOf(mine))
        assertArrayEquals(plain, passVaultDecrypt(sealed.readBytes(), mine))
    }

    @Test fun ageRefusesAPassVaultFileForAnotherKey() {
        // The official tool must not open a PassVault file without the right key: the test above is not passing by accident.
        val sealed = file("wrong.age", passVaultEncrypt(payload(100), Age.generateIdentity().recipient))
        val wrong = keyFile("wrong-key.txt", Age.generateIdentity().encoded)
        val process = ProcessBuilder(File(bin!!, "age").path, "-d", "-i", wrong.path, sealed.path).start()
        process.inputStream.readBytes(); process.errorStream.readBytes()
        assertTrue(process.waitFor(60, TimeUnit.SECONDS)); assertNotEquals(0, process.exitValue())
    }
}
