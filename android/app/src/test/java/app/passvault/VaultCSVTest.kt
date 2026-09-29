package app.passvault

import org.junit.Assert.*
import org.junit.Test

class VaultCSVTest {
    @Test fun quotedMultilineAndOrderedFieldsRoundtrip() {
        val record = VaultRecord(name = "Example, Inc.", fields = listOf(VaultField(kind = FieldKind.question, label = "Recovery", question = "Which city?", value = "test-only answer"), VaultField(kind = FieldKind.note, label = "Note", value = "one\r\ntwo \"quoted\"")))
        val restored = VaultCSV.importRecords(VaultCSV.exportRecords(listOf(record))).single()
        assertEquals(record.name, restored.name); assertEquals(record.fields, restored.fields)
    }
    @Test fun blackberryBasicAndUnknownCustomPayload() {
        val csv = "url,username,password,extra,name,grouping,fav,customFields\r\nhttps://example.test,user,test-only,notes,Example,Work,1,opaque\r\n"
        val record = VaultCSV.importRecords(csv).single()
        assertTrue(record.favorite); assertEquals("Work", record.group)
        assertEquals("opaque", record.fields.last().value); assertTrue(record.fields.last().secret)
        assertFalse(record.legacy.containsKey("password"))
    }
    @Test fun malformedInputRejected() {
        for (text in listOf("a,\"unterminated", "\"a\"garbage")) {
            assertThrows(IllegalArgumentException::class.java) { VaultCSV.parse(text) }
        }
        assertThrows(IllegalArgumentException::class.java) { VaultCSV.importRecords("name,username,password\na,b") }
    }
    @Test fun duplicateIdentifiersRejected() {
        val record = VaultRecord(name = "test")
        assertThrows(IllegalArgumentException::class.java) { Records.validate(listOf(record, record)) }
    }
    @Test fun passwordKeeperExportShape() {
        // Same layout as a Password Keeper backup: 18 quoted columns, empty unquoted cells, LF endings, trailing newline.
        val csv = "\"url\",\"username\",\"password\",\"extra\",\"name\",\"grouping\",\"fav\",\"customFields\",\"lastModifiedTime\",\"uid\",\"usernameLabel\",\"passwordLabel\",\"websiteLabel\",\"notesLabel\",\"passwordSetDate\",\"flags\",\"imageIndex\",\"dataVersion\"\n" +
            "\"example.com\",\"user\",\"test-only\",\"some note\",\"Site\",,\"0\",,\"1700000000\",\"0123456789abcdef0123456789abcdef\",,,,,\"1700000000\",\"0\",\"0\",\"1\"\n"
        val record = VaultCSV.importRecords(csv).single()
        assertEquals("Site", record.name); assertEquals("example.com", record.website); assertFalse(record.favorite)
        assertEquals(listOf("user", "test-only", "some note"), record.fields.map { it.value })
        assertEquals("0123456789abcdef0123456789abcdef", record.legacy["uid"])
    }
    // Optional: PASSVAULT_TEST_CSV=/path/to/export.csv ./gradlew :app:testDebugUnitTest checks a real local export without logging contents.
    @Test fun localMigrationFile() {
        val path = System.getenv("PASSVAULT_TEST_CSV") ?: return
        val records = VaultCSV.importRecords(java.io.File(path).readText())
        assertTrue(records.isNotEmpty())
        for (record in records) {
            assertEquals(listOf(FieldKind.username, FieldKind.password, FieldKind.note).take(3), record.fields.take(3).map { it.kind })
            val basic = record.fields.take(3)
            assertTrue("empty basic field in a record", basic.any { it.value.isNotEmpty() })
        }
        println("Imported ${records.size} records with field counts ${records.map { it.fields.size }}")
    }
    @Test fun passwordRule() {
        assertNull(PasswordPolicy.problem("Abcdefghij1!"))
        for (weak in listOf("Abcdefghi1!", "Abcdef1!", "abcdefghij1!", "ABCDEFGHIJ1!", "Abcdefghijk!", "Abcdefghijk1", "Abc def ghi 1")) assertNotNull(weak, PasswordPolicy.problem(weak))
    }
    @Test fun generatorHonoursOptions() {
        repeat(50) {
            val p = PasswordGenerator.generate(GeneratorOptions())
            assertEquals(10, p.length)
            assertTrue(p.any { it.isUpperCase() } && p.any { it.isLowerCase() } && p.any { it.isDigit() } && p.any { it in GeneratorOptions.SYMBOLS })
        }
        assertTrue(PasswordGenerator.generate(GeneratorOptions(length = 8, letters = false, symbols = false)).all { it.isDigit() })
        assertThrows(IllegalArgumentException::class.java) { PasswordGenerator.generate(GeneratorOptions(letters = false, numbers = false, symbols = false)) }
    }
    @Test fun bip39Vectors() {
        fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        val vectors = mapOf(
            "00000000000000000000000000000000" to "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f" to "legal winner thank year wave sausage worth useful legal winner thank yellow",
            "80808080808080808080808080808080" to "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
            "ffffffffffffffffffffffffffffffff" to "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
            "9e885d952ad362caeb4efe34a8e91bd2" to "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic",
            "0000000000000000000000000000000000000000000000000000000000000000" to "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
            "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f" to "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title",
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" to "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
        )
        for ((entropy, phrase) in vectors) {
            assertEquals(phrase, Bip39.fromEntropy(hex(entropy)).joinToString(" "))
            assertNull(Bip39.problem(Bip39.split(phrase)))
        }
        assertNotNull(Bip39.problem(Bip39.split("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon")))
        assertNotNull(Bip39.problem(Bip39.split("abandon abandon abandon")))
        for (count in Bip39.WORD_COUNTS) repeat(20) { val words = Bip39.generate(count); assertEquals(count, words.size); assertNull(Bip39.problem(words)) }
        assertEquals(listOf("abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract"), Bip39.suggestions("ab"))
    }
    @Test fun seedsNeverInCsvButSurviveRecordEncoding() {
        val seed = VaultRecord(name = "Wallet", type = RecordType.seed, fields = listOf(VaultField(kind = FieldKind.password, label = SEED_LABEL, value = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong")))
        val login = VaultRecord(name = "Site")
        val csv = VaultCSV.exportRecords(listOf(seed, login))
        assertFalse(csv.contains("zoo")); assertFalse(csv.contains("Wallet")); assertTrue(csv.contains("Site"))
        val decoded = Records.decode(Records.encode(listOf(seed, login)))
        assertEquals(RecordType.seed, decoded[0].type); assertEquals(12, decoded[0].seedWords.size); assertEquals(RecordType.login, decoded[1].type)
    }
}
