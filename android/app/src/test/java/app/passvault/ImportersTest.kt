package app.passvault

import org.junit.Assert.*
import org.junit.Test

/** Exports shaped like each manager's documented format. All values are test-only. */
class ImportersTest {
    private fun import(text: String) = Importers.importPlain(text.toByteArray())
    private fun VaultRecord.value(label: String) = fields.first { it.label == label }.value
    private val totpUri = "otpauth://totp/Example:me?secret=JBSWY3DPEHPK3PXP&issuer=Example"

    @Test fun chromeAndEdge() {
        val r = import("name,url,username,password,note\r\nexample.com,https://example.com/login,me@example.com,test-only-1,hello\r\n").single()
        assertEquals("example.com", r.name); assertEquals("https://example.com/login", r.website)
        assertEquals(listOf("me@example.com", "test-only-1", "hello"), r.fields.take(3).map { it.value })
    }
    @Test fun firefoxNamesFromHostAndKeepsPasswordDate() {
        val r = import("\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\",\"timeCreated\",\"timeLastUsed\",\"timePasswordChanged\"\n" +
            "\"https://www.example.org\",\"me\",\"test-only-2\",,\"https://www.example.org\",\"{abc}\",\"1600000000000\",\"1600000000000\",\"1500000000000\"\n").single()
        assertEquals("example.org", r.name); assertEquals("1500000000", r.legacy["passwordSetDate"]); assertEquals("{abc}", r.legacy["guid"])
    }
    @Test fun bitwardenCsv() {
        val records = import("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n" +
            "Work,1,login,Mail,n1,\"PIN: 1234\nRecovery: abc\",0,\"https://mail.example\nhttps://alt.example\",me,test-only-3,$totpUri\n" +
            ",,note,Wi-Fi,the code is 42,,0,,,,\n")
        val login = records.first { it.name == "Mail" }
        assertTrue(login.favorite); assertEquals("Work", login.group); assertEquals("https://mail.example", login.website)
        assertEquals("1234", login.value("PIN")); assertEquals("https://alt.example", login.value("Website"))
        assertEquals("me", records.single { it.type == RecordType.totp }.totp!!.account.ifEmpty { "me" })
        assertEquals(RecordType.note, records.single { it.name == "Wi-Fi" }.type)
    }
    @Test fun onePasswordAndSafariCsv() {
        val one = import("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nBank,https://bank.example,me,test-only-4,,true,false,\"Finance,Money\",n\n").single()
        assertEquals("Finance", one.group); assertTrue(one.favorite)
        val safari = import("Title,URL,Username,Password,Notes,OTPAuth\nShop,https://shop.example,me,test-only-5,,$totpUri\n")
        assertEquals(listOf(RecordType.login, RecordType.totp), safari.map { it.type })
    }
    @Test fun keePassXcAndKeePassCsv() {
        val xc = import("\"Group\",\"Title\",\"Username\",\"Password\",\"URL\",\"Notes\",\"TOTP\",\"Icon\",\"Last Modified\",\"Created\"\n" +
            "\"Root/Email\",\"Mail\",\"me\",\"test-only-6\",\"https://mail.example\",\"\",\"\",\"0\",\"2026-01-01T00:00:00Z\",\"2026-01-01T00:00:00Z\"\n" +
            "\"Root\",\"Top\",\"me\",\"test-only-7\",\"\",\"\",\"\",\"0\",\"\",\"\"\n")
        assertEquals(listOf("Email", ""), xc.map { it.group })
        val kp = import("\"Account\",\"Login Name\",\"Password\",\"Web Site\",\"Comments\"\n\"Forum\",\"me\",\"test-only-8\",\"https://forum.example\",\"c\"\n").single()
        assertEquals("Forum", kp.name); assertEquals("https://forum.example", kp.website); assertEquals("c", kp.value("Notes"))
    }
    @Test fun passwordKeeperCsvStillUsesItsOwnImporter() {
        val r = import("url,username,password,extra,name,grouping,fav,customFields\r\nhttps://example.test,user,test-only,notes,Example,Work,1,opaque\r\n").single()
        assertEquals("opaque", r.fields.last().value)
    }
    @Test fun unrecognisedCsvIsRejected() {
        assertThrows(IllegalArgumentException::class.java) { import("a,b,c\n1,2,3\n") }
    }
    @Test fun bitwardenJson() {
        val json = """{"encrypted":false,"folders":[{"id":"f1","name":"Personal"}],"items":[
            {"id":"1","folderId":"f1","type":1,"name":"Mail","notes":"n","favorite":true,"fields":[{"name":"PIN","value":"1234","type":1},{"name":"Plan","value":"pro","type":0}],
             "login":{"uris":[{"match":null,"uri":"https://mail.example"}],"username":"me","password":"test-only-9","totp":"JBSWY3DPEHPK3PXP"},
             "passwordHistory":[{"lastUsedDate":"2025-01-01T00:00:00.000Z","password":"older"}],"revisionDate":"2026-01-01T00:00:00.000Z","deletedDate":null},
            {"id":"2","folderId":null,"type":3,"name":"Visa","notes":null,"favorite":false,"card":{"cardholderName":"Me","brand":"Visa","number":"4111111111111111","expMonth":"3","expYear":"2027","code":"123"}},
            {"id":"3","type":2,"name":"Door code","notes":"4321","secureNote":{"type":0}},
            {"id":"4","type":4,"name":"Me","identity":{"firstName":"Ann","lastName":"Lee","passportNumber":"X1","email":null}},
            {"id":"5","type":1,"name":"Gone","login":{"password":"x"},"deletedDate":"2026-02-01T00:00:00.000Z"}]}"""
        val records = import(json)
        val mail = records.single { it.name == "Mail" && it.type == RecordType.login }
        assertEquals("Personal", mail.group); assertTrue(mail.favorite)
        assertEquals(listOf("older"), mail.fields[1].history.map { it.value })
        assertTrue(mail.fields.first { it.label == "PIN" }.secret); assertFalse(mail.fields.first { it.label == "Plan" }.secret)
        assertTrue(records.any { it.type == RecordType.totp && it.name == "Mail" })
        val card = records.single { it.type == RecordType.card }
        assertEquals("Visa •••• 1111", card.cardSummary); assertEquals("03/27", card.value(CARD_EXPIRY_LABEL)); assertEquals("123", card.value(CARD_CODE_LABEL))
        assertEquals("4321", records.single { it.name == "Door code" }.value("Notes"))
        val identity = records.single { it.name == "Me" }
        assertEquals(RecordType.note, identity.type); assertEquals("Ann", identity.value("First name")); assertTrue(identity.fields.first { it.label == "Passport number" }.secret)
        assertTrue(records.none { it.name == "Gone" })
        assertThrows(IllegalArgumentException::class.java) { import("""{"encrypted":true,"passwordProtected":true,"data":"..."}""") }
    }
    @Test fun onePux() {
        // Shared with iOS; see fixtures/exports/README.md.
        val zip = java.io.File("../../fixtures/exports/sample.1pux").readBytes()
        val records = Importers.importPlain(zip)
        val mail = records.single { it.name == "Mail" && it.type == RecordType.login }
        assertEquals("Work", mail.group); assertTrue(mail.favorite); assertEquals(listOf("me", "test-only-10", "n"), mail.fields.take(3).map { it.value })
        assertEquals(listOf("older"), mail.fields[1].history.map { it.value }); assertTrue(mail.fields.first { it.label == "recovery" }.secret)
        assertTrue(records.any { it.type == RecordType.totp })
        val card = records.single { it.type == RecordType.card }
        assertEquals("Mastercard •••• 0004", card.cardSummary); assertEquals("12/27", card.value(CARD_EXPIRY_LABEL)); assertEquals("999", card.value(CARD_CODE_LABEL))
        assertEquals("Big Bank", card.value("bank")); assertEquals(1, card.fields.count { it.value == "999" })
        assertTrue(records.none { it.name == "Old" }); assertEquals("keep me", records.single { it.name == "Note" }.value("Notes"))
    }
    @Test fun onePuxKeepsEveryUrlAndCardYearsOutsideThisCentury() {
        val data = """{"accounts":[{"vaults":[{"attrs":{"name":"Private"},"items":[
            {"categoryUuid":"001","overview":{"title":"Shop","url":"https://shop.example","urls":[{"url":"https://shop.example"},{"url":"https://checkout.example"},{"url":" "}]},"details":{"password":"test-only-12"}},
            {"categoryUuid":"002","overview":{"title":"Old card"},"details":{"sections":[{"fields":[{"id":"expiry","title":"expiry","value":{"monthYear":199912}}]}]}}]}]}]}"""
        val zip = java.io.ByteArrayOutputStream().also { out -> java.util.zip.ZipOutputStream(out).use { it.putNextEntry(java.util.zip.ZipEntry("export.data")); it.write(data.toByteArray()) } }.toByteArray()
        val records = Importers.importPlain(zip)
        val shop = records.single { it.name == "Shop" }
        assertEquals("https://shop.example", shop.website); assertEquals(listOf("https://checkout.example"), shop.fields.filter { it.label == "Website" }.map { it.value })
        val card = records.single { it.type == RecordType.card }
        assertEquals("12/1999", card.value(CARD_EXPIRY_LABEL)); assertEquals(ExpiryState.expired, card.expiryState())
        assertEquals("12/27", ImportBuilder.cardExpiry("12", "2027")); assertEquals("03/27", ImportBuilder.cardExpiry("3", "27")); assertEquals("01/2101", ImportBuilder.cardExpiry("1", "2101"))
    }
    @Test fun totpValuesThatAreNotKeysAreKept() {
        val records = import("name,url,username,password,totp\nGame,,me,test-only-11,steam://ABCDEF\n")
        assertEquals(1, records.size); assertEquals("steam://ABCDEF", records[0].value("One-time password"))
    }
    @Test fun nestedFoldersOutsideKeePassXcAreKept() {
        val records = import("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\nWork/Email,,login,A,,,0,,me,p1,\nWork/Bank,,login,B,,,0,,me,p2,\nWork,,login,C,,,0,,me,p3,\n")
        assertEquals(listOf("Work/Email", "Work/Bank", "Work"), records.map { it.group })
    }
}
