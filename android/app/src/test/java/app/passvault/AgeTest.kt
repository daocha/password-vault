package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/** The age test kit (CCTV, see fixtures/age-testkit/README.md) and round trips through the encrypter. */
class AgeTest {
    private val dir = File("../../fixtures/age-testkit")
    private class Vector(val name: String, val expect: String, val payload: String?, val identities: List<String>, val armored: Boolean, val passphrase: Boolean, val file: ByteArray)
    private fun vectors(): List<Vector> = dir.listFiles()!!.filter { it.isFile && it.name != "README.md" }.sortedBy { it.name }.map { f ->
        val bytes = f.readBytes(); val split = (0 until bytes.size - 1).first { bytes[it] == '\n'.code.toByte() && bytes[it + 1] == '\n'.code.toByte() }
        val headers = String(bytes, 0, split, Charsets.UTF_8).lines().map { it.substringBefore(": ") to it.substringAfter(": ") }
        fun value(key: String) = headers.firstOrNull { it.first == key }?.second
        var body = bytes.copyOfRange(split + 2, bytes.size)
        if (value("compressed") == "zlib") body = java.util.zip.InflaterInputStream(ByteArrayInputStream(body)).readBytes()
        Vector(f.name, value("expect")!!, value("payload"), headers.filter { it.first == "identity" }.map { it.second }, value("armored") == "yes", value("passphrase") != null, body)
    }
    private fun outcome(kind: AgeException.Kind) = when (kind) {
        AgeException.Kind.header -> "header failure"; AgeException.Kind.noMatch -> "no match"; AgeException.Kind.hmac -> "HMAC failure"
        AgeException.Kind.payload -> "payload failure"; AgeException.Kind.armor -> "armor failure"
    }
    private fun sha256(data: ByteArray) = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    @Test fun testKit() {
        // Passphrase (scrypt) files are not supported by design: PassVault encrypts only to the vault's key.
        val usable = vectors().filter { !it.passphrase }
        assertTrue("test kit present", usable.size > 100)
        assertTrue("post-quantum files decrypt", usable.count { it.name.startsWith("hybrid") && it.expect == "success" } >= 4)
        val failures = usable.mapNotNull { v ->
            val out = ByteArrayOutputStream()
            val got = try {
                val identities = v.identities.map(Age::parseIdentity)
                val input = if (v.armored) Age.dearmor(v.file) else v.file
                Age.decryptBinary(ByteArrayInputStream(input), out, identities); "success"
            } catch (e: AgeException) { outcome(e.kind) }
            when {
                got != v.expect -> "${v.name}: expected ${v.expect}, got $got"
                got == "success" && v.payload != null && sha256(out.toByteArray()) != v.payload -> "${v.name}: wrong payload"
                else -> null
            }
        }
        assertEquals(emptyList<String>(), failures)
    }

    @Test fun armorIsDetectedAutomatically() {
        val v = vectors().first { it.name == "armor_whitespace_outside" }
        val out = ByteArrayOutputStream(); Age.decrypt(ByteArrayInputStream(v.file), out, v.identities.map(Age::parseIdentity))
        assertEquals(v.payload, sha256(out.toByteArray()))
        val binary = vectors().first { it.name == "stream_three_chunks" }
        val out2 = ByteArrayOutputStream(); Age.decrypt(ByteArrayInputStream(binary.file), out2, binary.identities.map(Age::parseIdentity))
        assertEquals(binary.payload, sha256(out2.toByteArray()))
    }

    @Test fun roundTripsAtChunkBoundaries() {
        val hybrid = Age.generateIdentity(); val classic = Age.parseIdentity("AGE-SECRET-KEY-1EGTZVFFV20835NWYV6270LXYVK2VKNX2MMDKWYKLMGR48UAWX40Q2P2LM0")
        for (identity in listOf(hybrid, classic)) for (size in listOf(0, 1, Age.CHUNK - 1, Age.CHUNK, Age.CHUNK + 1, 2 * Age.CHUNK, 3 * Age.CHUNK + 17)) {
            val plain = ByteArray(size) { (it * 31 + 7).toByte() }
            val sealed = ByteArrayOutputStream().also { Age.encrypt(ByteArrayInputStream(plain), it, listOf(Age.parseRecipient(identity.recipient.encoded))) }.toByteArray()
            assertEquals("size $size", maxOf(1, (size + Age.CHUNK - 1) / Age.CHUNK), (sealed.size - headerSize(sealed) - 16 - size) / 16)
            val opened = ByteArrayOutputStream().also { Age.decrypt(ByteArrayInputStream(sealed), it, listOf(identity)) }.toByteArray()
            assertArrayEquals("size $size", plain, opened)
            // Each file gets a fresh file key and nonce.
            val again = ByteArrayOutputStream().also { Age.encrypt(ByteArrayInputStream(plain), it, listOf(identity.recipient)) }.toByteArray()
            assertFalse(sealed.contentEquals(again))
        }
    }
    private fun headerSize(file: ByteArray): Int { val text = String(file, Charsets.ISO_8859_1); return text.indexOf('\n', text.indexOf("\n--- ") + 1) + 1 }

    @Test fun otherKeysAndTamperingAreRejected() {
        val identity = Age.generateIdentity(); val other = Age.generateIdentity()
        val sealed = ByteArrayOutputStream().also { Age.encrypt(ByteArrayInputStream(ByteArray(100_000) { it.toByte() }), it, listOf(identity.recipient)) }.toByteArray()
        assertEquals(AgeException.Kind.noMatch, assertThrows(AgeException::class.java) { Age.decrypt(ByteArrayInputStream(sealed), ByteArrayOutputStream(), listOf(other)) }.kind)
        // The right key among several is found.
        Age.decrypt(ByteArrayInputStream(sealed), ByteArrayOutputStream(), listOf(other, identity))
        val flipped = sealed.copyOf().also { it[it.size - 20] = (it[it.size - 20].toInt() xor 1).toByte() }
        assertEquals(AgeException.Kind.payload, assertThrows(AgeException::class.java) { Age.decrypt(ByteArrayInputStream(flipped), ByteArrayOutputStream(), listOf(identity)) }.kind)
        val truncated = sealed.copyOf(sealed.size - Age.CHUNK / 2)
        assertEquals(AgeException.Kind.payload, assertThrows(AgeException::class.java) { Age.decrypt(ByteArrayInputStream(truncated), ByteArrayOutputStream(), listOf(identity)) }.kind)
    }

    @Test fun keyEncodingsMatchAge() {
        // From the age specification (c2sp.org/age): this X25519 identity and its recipient.
        val spec = Age.parseIdentity("AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX")
        assertEquals("age1zvkyg2lqzraa2lnjvqej32nkuu0ues2s82hzrye869xeexvn73equnujwj", spec.recipient.encoded)
        assertEquals("AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX", spec.encoded)
        val (pqIdentity, pqRecipient) = File("../../fixtures/age-spec/hybrid-key.txt").readLines()
        assertEquals(pqRecipient, Age.parseIdentity(pqIdentity).recipient.encoded)
        assertEquals(pqIdentity, Age.parseIdentity(pqIdentity).encoded)
        val pq = Age.generateIdentity()
        assertTrue(pq.encoded.startsWith("AGE-SECRET-KEY-PQ-1")); assertTrue(pq.recipient.encoded.startsWith("age1pq1"))
        assertEquals(pq.recipient.encoded, Age.parseIdentity(pq.encoded.lowercase()).recipient.encoded)
        for (bad in listOf("", "age1zvkyg2lqzraa2lnjvqej32nkuu0ues2s82hzrye869xeexvn73equnujwj", "AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEY", "AGE-secret-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX"))
            assertFalse(bad, Age.isIdentity(bad))
        assertThrows(IllegalArgumentException::class.java) { Age.parseRecipient(spec.encoded) }
    }
}
