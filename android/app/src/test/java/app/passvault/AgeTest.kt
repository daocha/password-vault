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
    private class Vector(val name: String, val expect: String, val payload: String?, val identities: List<String>, val armored: Boolean, val passphrase: Boolean, val comment: String?, val file: ByteArray)
    private fun vectors(): List<Vector> = dir.listFiles()!!.filter { it.isFile && it.name != "README.md" }.sortedBy { it.name }.map { f ->
        val bytes = f.readBytes(); val split = (0 until bytes.size - 1).first { bytes[it] == '\n'.code.toByte() && bytes[it + 1] == '\n'.code.toByte() }
        val headers = String(bytes, 0, split, Charsets.UTF_8).lines().map { it.substringBefore(": ") to it.substringAfter(": ") }
        fun value(key: String) = headers.firstOrNull { it.first == key }?.second
        var body = bytes.copyOfRange(split + 2, bytes.size)
        if (value("compressed") == "zlib") body = java.util.zip.InflaterInputStream(ByteArrayInputStream(body)).readBytes()
        Vector(f.name, value("expect")!!, value("payload"), headers.filter { it.first == "identity" }.map { it.second }, value("armored") == "yes", value("passphrase") != null, value("comment"), body)
    }
    private fun outcome(kind: AgeException.Kind) = when (kind) {
        AgeException.Kind.header -> "header failure"; AgeException.Kind.noMatch, AgeException.Kind.passphrase -> "no match"; AgeException.Kind.hmac -> "HMAC failure"
        AgeException.Kind.payload -> "payload failure"; AgeException.Kind.armor -> "armor failure"
    }
    private fun sha256(data: ByteArray) = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    /**
     * Acceptable outcomes. Passphrase (scrypt) files cannot be opened by design (PassVault encrypts only to the vault's keys), so a
     * passphrase vector never succeeds: it ends in "no match", or in "header failure" when its header is malformed (PassVault checks the
     * stanza grammar shared by all types, not scrypt's own arguments). Headers mixing scrypt with other stanzas must be rejected (spec).
     */
    private fun expected(v: Vector) = when {
        !v.passphrase -> setOf(v.expect)
        v.comment?.contains("must be alone") == true -> setOf("header failure")
        v.expect == "header failure" -> setOf("header failure", "no match")
        else -> setOf("no match")
    }
    @Test fun testKit() {
        val all = vectors()
        assertTrue("test kit present", all.size > 140)
        assertTrue("post-quantum files decrypt", all.count { it.name.startsWith("hybrid") && it.expect == "success" } >= 4)
        assertEquals("mixed passphrase headers covered", 2, all.count { it.passphrase && expected(it) == setOf("header failure") })
        val failures = all.mapNotNull { v ->
            val out = ByteArrayOutputStream()
            val got = try {
                val identities = v.identities.map(Age::parseIdentity)
                val input = if (v.armored) Age.dearmor(v.file) else v.file
                Age.decryptBinary(ByteArrayInputStream(input), out, identities); "success"
            } catch (e: AgeException) { outcome(e.kind) }
            when {
                got !in expected(v) -> "${v.name}: expected ${expected(v)}, got $got"
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

    @Test fun passphraseFilesSaySo() {
        // Told apart from "not your key": the file uses a kind of protection PassVault does not open.
        val v = vectors().first { it.name == "scrypt" }
        assertEquals(AgeException.Kind.passphrase, assertThrows(AgeException::class.java) { Age.decrypt(ByteArrayInputStream(v.file), ByteArrayOutputStream(), listOf(Age.generateIdentity())) }.kind)
    }

    @Test fun armoredFilesAreDecodedAsTheyAreRead() {
        val identity = Age.generateIdentity(); val plain = ByteArray(3 * 1024 * 1024 + 5) { (it * 7).toByte() }
        val sealed = ByteArrayOutputStream().also { Age.encrypt(ByteArrayInputStream(plain), it, listOf(identity.recipient)) }.toByteArray()
        val armored = ("-----BEGIN AGE ENCRYPTED FILE-----\r\n" + java.util.Base64.getEncoder().encodeToString(sealed).chunked(64).joinToString("\r\n") +
            "\r\n-----END AGE ENCRYPTED FILE-----\n").toByteArray()
        var read = 0L
        fun counting() = object : java.io.FilterInputStream(ByteArrayInputStream(armored)) {
            override fun read(): Int = super.read().also { if (it >= 0) read++ }
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { if (it > 0) read += it }
        }
        // Checking the header reads about one buffer of a multi-megabyte armored file, not all of it.
        Age.checkHeader(counting(), listOf(identity))
        assertTrue("read $read bytes", read < 256 * 1024)
        val out = ByteArrayOutputStream(); Age.decrypt(counting(), out, listOf(identity))
        assertArrayEquals(plain, out.toByteArray())
        // Damage near the end surfaces as an armor failure once the reader gets there.
        val damaged = armored.copyOf().also { it[it.size - 60] = '!'.code.toByte() }
        assertEquals(AgeException.Kind.armor, assertThrows(AgeException::class.java) { Age.decrypt(ByteArrayInputStream(damaged), ByteArrayOutputStream(), listOf(identity)) }.kind)
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

    @Test fun plaintextIsWipedWhenWritingFails() {
        val identity = Age.generateIdentity(); val plain = ByteArray(2 * Age.CHUNK + 17) { (it % 251 + 1).toByte() }
        // Encrypting: the buffers the plaintext was read into hold none of it after the first chunk fails to write.
        val readInto = ArrayList<ByteArray>()
        val input = object : ByteArrayInputStream(plain) {
            override fun read(b: ByteArray, off: Int, len: Int): Int { if (readInto.none { it === b }) readInto += b; return super.read(b, off, len) }
        }
        val failingChunks = object : ByteArrayOutputStream() {
            override fun write(b: ByteArray, off: Int, len: Int) { if (len > Age.CHUNK) throw java.io.IOException("disk full"); super.write(b, off, len) }
        }
        assertThrows(java.io.IOException::class.java) { Age.encrypt(input, failingChunks, listOf(identity.recipient)) }
        assertEquals("both chunk buffers were filled", 2, readInto.size)
        for (buffer in readInto) assertTrue("plaintext wiped", buffer.all { it == 0.toByte() })
        // Decrypting: the chunk handed to a failing output is wiped too.
        val sealed = ByteArrayOutputStream().also { Age.encrypt(ByteArrayInputStream(plain), it, listOf(identity.recipient)) }.toByteArray()
        var written: ByteArray? = null
        val failing = object : java.io.OutputStream() {
            override fun write(b: Int) = throw java.io.IOException("disk full")
            override fun write(b: ByteArray, off: Int, len: Int) { written = b; throw java.io.IOException("disk full") }
        }
        assertThrows(java.io.IOException::class.java) { Age.decrypt(ByteArrayInputStream(sealed), failing, listOf(identity)) }
        assertEquals(Age.CHUNK, written!!.size)
        assertTrue("plaintext wiped", written!!.all { it == 0.toByte() })
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
