package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Real KeePass and KeePassXC databases from kdbxweb (see fixtures/kdbxweb/README.md). */
class KeePassTest {
    private val dir = File("../../fixtures/kdbxweb")
    private fun file(name: String) = File(dir, name).readBytes()
    /** The entry every "demo" database holds, checked field by field. */
    private fun checkDemo(records: List<VaultRecord>) {
        val entry = records.single { it.name == "my entry" }
        assertEquals("General", entry.group) // "sample" is the database root
        assertEquals("http://me.me", entry.website)
        assertEquals(listOf("me", "mypass", "some notes"), entry.fields.take(3).map { it.value })
        assertEquals("my val", entry.fields.single { it.label == "my field" }.value)
        val protected = entry.fields.single { it.label == "my field protected" }
        assertEquals("protected val", protected.value); assertTrue(protected.secret)
        assertEquals(listOf("pass"), entry.fields[1].history.map { it.value })
        assertEquals("2015-08-29", entry.expires.take(10).let { if (it == "2015-08-30") "2015-08-29" else it }) // 21:00 UTC is the 30th east of UTC+3
        assertTrue("recycle bin skipped", records.none { it.group.contains("Recycle Bin") })
    }
    @Test fun demoDatabasesInEveryCipherAndKdf() {
        for (name in listOf("demo.kdbx", "Argon2.kdbx", "Argon2id.kdbx", "Argon2ChaCha.kdbx", "AesChaCha.kdbx")) {
            assertTrue(name, Kdbx.isKdbx(file(name)))
            checkDemo(Kdbx.import(file(name), "demo", file("demo.key")))
        }
    }
    @Test fun wrongCredentialsAreRejected() {
        assertThrows(AuthenticationFailure::class.java) { Kdbx.import(file("demo.kdbx"), "wrong", file("demo.key")) }
        assertThrows(AuthenticationFailure::class.java) { Kdbx.import(file("Argon2.kdbx"), "demo", null) }
        assertThrows(AuthenticationFailure::class.java) { Kdbx.import(file("cyrillic.kdbx"), "пароль1", null) }
    }
    @Test fun otherDatabases() {
        assertTrue(Kdbx.import(file("cyrillic.kdbx"), "пароль", null).isNotEmpty())
        assertTrue(Kdbx.import(file("AesKdfKdbx4.kdbx"), "demo", null).isNotEmpty())
        assertTrue(Kdbx.import(file("KDBX4.1.kdbx"), "test", null).isNotEmpty())
        Kdbx.import(file("EmptyPass.kdbx"), "", null)
        for ((db, key) in listOf("Key32" to "Key32.key", "Key64" to "Key64.key", "KeyWithBom" to "KeyWithBom.key", "binkey" to "binkey.key")) Kdbx.import(file("$db.kdbx"), "test", file(key))
        Kdbx.import(file("KeyV2.kdbx"), null, file("KeyV2.keyx"))
        // An empty password box with a key file means "no password" first.
        Kdbx.importTyped(file("NoPassWithKeyFile.kdbx"), "", file("NoPassWithKeyFile.key"))
    }
    @Test fun keePassXmlExport() {
        val records = Importers.importPlain(file("demo.xml"))
        checkDemo(records)
    }
    @Test fun xmlReaderRefusesDoctypeAndBadMarkup() {
        val evil = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><KeePassFile>&e;</KeePassFile>"
        assertThrows(IllegalArgumentException::class.java) { MiniXml.parse(evil) }
        for (bad in listOf("<a><b></a>", "<a>", "<a x=1/>", "text", "<a>&unknown;</a>", "<a/><b/>")) assertThrows(bad, IllegalArgumentException::class.java) { MiniXml.parse(bad) }
        val ok = MiniXml.parse("<?xml version=\"1.0\"?><!-- c --><a k='v &amp; w'><b>x &lt;y&gt; &#65;&#x42;</b><c><![CDATA[<raw>]]></c><d/></a>")
        assertEquals("v & w", ok.attributes["k"]); assertEquals("x <y> AB", ok.child("b")!!.text); assertEquals("<raw>", ok.child("c")!!.text); assertNotNull(ok.child("d"))
    }
    @Test fun argon2MatchesRfc9106() {
        // RFC 9106 §5 vectors (also checked on iOS against its own Argon2).
        for ((type, expected) in listOf(org.bouncycastle.crypto.params.Argon2Parameters.ARGON2_d to "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb",
                org.bouncycastle.crypto.params.Argon2Parameters.ARGON2_id to "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")) {
            val params = org.bouncycastle.crypto.params.Argon2Parameters.Builder(type).withVersion(org.bouncycastle.crypto.params.Argon2Parameters.ARGON2_VERSION_13)
                .withIterations(3).withMemoryAsKB(32).withParallelism(4).withSalt(ByteArray(16) { 2 }).withSecret(ByteArray(8) { 3 }).withAdditional(ByteArray(12) { 4 }).build()
            val out = ByteArray(32); org.bouncycastle.crypto.generators.Argon2BytesGenerator().apply { init(params) }.generateBytes(ByteArray(32) { 1 }, out)
            assertEquals(expected, out.joinToString("") { "%02x".format(it) })
        }
    }
    @Test fun keyFileFormats() {
        assertArrayEquals(ByteArray(32) { 7 }, KeyFile.key(ByteArray(32) { 7 }))
        assertArrayEquals(ByteArray(32) { 0xAB.toByte() }, KeyFile.key("ab".repeat(32).toByteArray()))
        assertEquals(32, KeyFile.key("any other file".toByteArray()).size)
    }
    @Test fun timesInBothEncodings() {
        assertEquals(java.time.Instant.parse("2015-08-16T14:45:54Z"), KeePassXml.time("2015-08-16T14:45:54Z"))
        // 63575333154 seconds since 0001-01-01, little-endian, Base64.
        val seconds = 62_135_596_800L + java.time.Instant.parse("2015-08-16T14:45:54Z").epochSecond
        val encoded = java.util.Base64.getEncoder().encodeToString(java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN).putLong(seconds).array())
        assertEquals(java.time.Instant.parse("2015-08-16T14:45:54Z"), KeePassXml.time(encoded))
    }
}
