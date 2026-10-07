package app.passvault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class TotpTest {
    private fun account(secret: String, algorithm: String) = TotpAccount(secret.toByteArray(), algorithm = algorithm, digits = 8, period = 30)

    @Test fun rfc6238Vectors() {
        val sha1 = account("12345678901234567890", "SHA1")
        val sha256 = account("12345678901234567890123456789012", "SHA256")
        val sha512 = account("1234567890".repeat(6) + "1234", "SHA512")
        val expected = mapOf(
            59L to listOf("94287082", "46119246", "90693936"),
            1111111109L to listOf("07081804", "68084774", "25091201"),
            1111111111L to listOf("14050471", "67062674", "99943326"),
            1234567890L to listOf("89005924", "91819424", "93441116"),
            2000000000L to listOf("69279037", "90698825", "38618901"),
            20000000000L to listOf("65353130", "77737706", "47863826"),
        )
        for ((time, codes) in expected) assertEquals("t=$time", codes, listOf(sha1, sha256, sha512).map { it.code(time) })
    }

    @Test fun sixDigitsAndCountdown() {
        val a = TotpAccount("12345678901234567890".toByteArray())
        assertEquals("287082", a.code(59))
        assertEquals(1, a.remaining(59)); assertEquals(30, a.remaining(60))
        assertEquals("287 082", formatTotpCode("287082")); assertEquals("1234 5678", formatTotpCode("12345678"))
    }

    @Test fun base32() {
        assertEquals("MZXW6YTBOI", Totp.base32("foobar".toByteArray()))
        assertEquals("foobar", Totp.decodeBase32("mzxw 6ytb-oi======").toString(Charsets.UTF_8))
        assertTrue(runCatching { Totp.decodeBase32("MZXW1") }.isFailure) // 1 is not Base32
        assertTrue(runCatching { Totp.decodeBase32("") }.isFailure)
    }

    @Test fun parsesAndRoundTripsUri() {
        val a = Totp.parseUri("otpauth://totp/ACME%20Co:john.doe+tag@email.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60")
        assertEquals("ACME Co", a.issuer); assertEquals("john.doe+tag@email.com", a.account)
        assertEquals("SHA256", a.algorithm); assertEquals(8, a.digits); assertEquals(60, a.period)
        assertEquals("HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ", a.secretBase32)
        assertEquals(a, Totp.parseUri(a.uri()))
        // Defaults, and the issuer taken from the label when there is no issuer parameter.
        val b = Totp.parseUri("otpauth://totp/Binance:me@example.com?secret=JBSWY3DPEHPK3PXP")
        assertEquals("Binance", b.issuer); assertEquals("me@example.com", b.account); assertEquals(6, b.digits); assertEquals(30, b.period); assertEquals("SHA1", b.algorithm)
        // Byte-for-byte the URI iOS writes, so backups made on either platform match.
        assertEquals("otpauth://totp/ACME%20Co:john.doe%2Btag%40email.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&algorithm=SHA1&digits=6&period=30",
            TotpAccount(Totp.decodeBase32("JBSWY3DPEHPK3PXP"), "ACME Co", "john.doe+tag@email.com").uri())
        val c = Totp.parseUri("otpauth://totp/me?secret=JBSWY3DPEHPK3PXP")
        assertEquals("", c.issuer); assertEquals("me", c.account)
    }

    @Test fun rejectsUnsupportedUris() {
        for (bad in listOf("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1", "https://example.com", "otpauth://totp/x", "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=4", "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5"))
            assertTrue(bad, runCatching { Totp.parseUri(bad) }.isFailure)
    }

    @Test fun recordStoresUriAndReadsBack() {
        val a = TotpAccount(Totp.decodeBase32("JBSWY3DPEHPK3PXP"), "GitHub", "octocat")
        val r = a.record()
        assertEquals(RecordType.totp, r.type); assertEquals("GitHub", r.name); assertEquals(a, r.totp)
        assertTrue(r.matches("octo"))
        val restored = Records.decode(Records.encode(listOf(r))).single()
        assertEquals(RecordType.totp, restored.type); assertEquals(a, restored.totp)
        assertNull(VaultRecord(type = RecordType.totp, fields = emptyList()).totp)
    }

    @Test fun totpRecordsStayOutOfCsv() {
        val login = VaultRecord(name = "site")
        val csv = VaultCSV.exportRecords(listOf(login, TotpAccount("12345678901234567890".toByteArray(), "X").record()))
        assertEquals(1, VaultCSV.importRecords(csv).size)
        assertTrue(!csv.contains("otpauth"))
    }

    private fun varint(v: Long): ByteArray { val out = java.io.ByteArrayOutputStream(); var x = v; while (true) { if (x and 0x7F.inv().toLong() == 0L) { out.write(x.toInt()); break }; out.write(((x and 0x7F) or 0x80).toInt()); x = x ushr 7 }; return out.toByteArray() }
    private fun bytesField(n: Int, b: ByteArray) = varint((n shl 3 or 2).toLong()) + varint(b.size.toLong()) + b
    private fun intField(n: Int, v: Long) = varint((n shl 3).toLong()) + varint(v)

    @Test fun parsesGoogleAuthenticatorExport() {
        val totp = bytesField(1, "12345678901234567890".toByteArray()) + bytesField(2, "Binance: me@example.com".toByteArray()) + bytesField(3, "Binance".toByteArray()) + intField(4, 1) + intField(5, 1) + intField(6, 2)
        val sha256 = bytesField(1, "abcdefghij".toByteArray()) + bytesField(2, "alice".toByteArray()) + intField(4, 2) + intField(5, 2) + intField(6, 2)
        val hotp = bytesField(1, "zzzzzzzzzz".toByteArray()) + bytesField(2, "counter".toByteArray()) + intField(6, 1) + intField(7, 5)
        val payload = bytesField(1, totp) + bytesField(1, sha256) + bytesField(1, hotp) + intField(2, 1) + intField(3, 1) + intField(4, 0) + intField(5, 12345)
        val data = java.net.URLEncoder.encode(Base64.getEncoder().encodeToString(payload), Charsets.UTF_8)
        val m = Totp.parseMigration("otpauth-migration://offline?data=$data")
        assertEquals(2, m.accounts.size); assertEquals(1, m.skipped)
        assertEquals("Binance", m.accounts[0].issuer); assertEquals("me@example.com", m.accounts[0].account); assertEquals("287082", m.accounts[0].code(59))
        assertEquals("SHA256", m.accounts[1].algorithm); assertEquals(8, m.accounts[1].digits); assertEquals("alice", m.accounts[1].account)
        assertTrue(runCatching { Totp.parseMigration("otpauth-migration://offline?data=AAAA%2B") }.isFailure)
        assertTrue(runCatching { Totp.parseMigration("otpauth-migration://offline?data=" + Base64.getEncoder().encodeToString(byteArrayOf(10, 50, 1))) }.isFailure)
    }
}
