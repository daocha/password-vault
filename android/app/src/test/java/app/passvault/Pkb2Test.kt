package app.passvault

import org.junit.Assert.*
import org.junit.Test

class Pkb2Test {
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun sample() = javaClass.getResourceAsStream("/sample.pkb2")!!.readBytes()

    // RFC 7914 section 12 test vectors.
    @Test fun scryptMatchesRfc7914() {
        assertEquals("77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906", hex(Scrypt.derive(ByteArray(0), ByteArray(0), 16, 1, 1, 64)))
        assertEquals("fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640", hex(Scrypt.derive("password".toByteArray(), "NaCl".toByteArray(), 1024, 8, 16, 64)))
    }

    @Test fun importsEveryFieldInOriginalOrder() {
        val records = Pkb2.import(sample(), "correct horse")
        assertEquals(3, records.size)
        val login = records[0]
        assertEquals("Sample login", login.name); assertEquals("example.com", login.website); assertTrue(login.favorite)
        assertEquals("2023-11-14T22:13:20Z", login.updatedAt); assertEquals("11111111111111111111111111111111", login.legacy["uid"])
        assertEquals(listOf(
            FieldKind.username to "alice", FieldKind.password to "Pw-one-1!", FieldKind.note to "first note",
            FieldKind.username to "alice2", FieldKind.password to "Pw-two-2!", FieldKind.note to "second note",
            FieldKind.question to "Rex", FieldKind.question to "Paris",
            FieldKind.note to "second.example.com", FieldKind.username to "bob", FieldKind.password to "Pw-three-3!", FieldKind.password to "typed-by-hand"), login.fields.map { it.kind to it.value })
        assertEquals(listOf("First pet?", "Birth city?"), login.fields.filter { it.kind == FieldKind.question }.map { it.question })
        assertEquals("Website", login.fields[8].label); assertEquals("Work login", login.fields[9].label); assertEquals("Username", login.fields[0].label)
        // Earlier passwords live in the password field's own history, newest change first; nothing is added as a "Previous password" field.
        assertEquals(listOf("Old-pw-0!" to 1690000000L, "Older-pw-9!" to 1680000000L), login.fields[4].historyNewestFirst.map { it.value to it.changedAtEpochSeconds })
        assertTrue(login.fields.filterIndexed { i, _ -> i != 4 }.all { it.history.isEmpty() })
        // A field the user typed and named "Previous password" is an ordinary field with no history.
        assertEquals("Previous password", login.fields[11].label); assertTrue(login.fields[11].history.isEmpty())
        assertEquals("Secure note", records[1].name); assertEquals("line1\nline2 é", records[1].fields.single().value)
        assertEquals(listOf("[ ] eggs", "[x] milk"), records[2].fields.map { it.value })
    }

    @Test fun historySurvivesVaultAndCsvRoundtrips() {
        val record = Pkb2.import(sample(), "correct horse")[0]
        val viaVault = Records.decode(Records.encode(listOf(record))).single()
        assertEquals(record.fields, viaVault.fields)
        assertEquals(record.fields, VaultCSV.importRecords(VaultCSV.exportRecords(listOf(record))).single().fields)
        // Records written before password history existed still load.
        val legacy = org.json.JSONObject().put("id", "a").put("kind", "password").put("label", "Password").put("value", "x").put("question", "")
        assertTrue(VaultField.from(legacy).history.isEmpty())
    }

    @Test fun changingAPasswordRecordsItsOldValueWithATimestamp() {
        val before = VaultRecord(fields = listOf(
            VaultField(kind = FieldKind.username, label = "Username", value = "alice"), VaultField(kind = FieldKind.password, label = "Password", value = "old-1"),
            VaultField(kind = FieldKind.question, label = "Security question", question = "Pet?", value = "answer-1"), VaultField(kind = FieldKind.note, label = "Notes", value = "n1"),
            VaultField(kind = FieldKind.password, label = "Previous password", value = "typed"), VaultField(kind = FieldKind.password, label = "Empty", value = "")))
        val at = java.time.Instant.ofEpochSecond(1_800_000_000)
        val after = before.copy(fields = before.fields.mapIndexed { i, f -> when (i) { 0 -> f.copy(value = "alice2"); 1 -> f.copy(value = "new-2"); 2 -> f.copy(value = "answer-2"); 3 -> f.copy(value = "n2"); 5 -> f.copy(value = "now-set"); else -> f } })
        val tracked = after.recordingPasswordChanges(before, at)
        assertEquals(listOf(PasswordChange("old-1", 1_800_000_000L)), tracked.fields[1].history)
        assertEquals(listOf(PasswordChange("answer-1", 1_800_000_000L)), tracked.fields[2].history)
        assertTrue("usernames, notes, unchanged and previously empty fields record nothing", listOf(0, 3, 4, 5).all { tracked.fields[it].history.isEmpty() })
        assertEquals(before, before.recordingPasswordChanges(before, at)); assertEquals(after, after.recordingPasswordChanges(null, at))
        val seed = before.copy(type = RecordType.seed); assertEquals(after.copy(type = RecordType.seed), after.copy(type = RecordType.seed).recordingPasswordChanges(seed, at))
        // Repeated changes accumulate, newest first, capped at the newest ten; an imported history is kept and extended.
        var chain = before
        for (n in 1..12) chain = chain.copy(fields = chain.fields.mapIndexed { i, f -> if (i == 1) f.copy(value = "pw-$n") else f }).recordingPasswordChanges(chain, java.time.Instant.ofEpochSecond(1_800_000_000L + n))
        val kept = chain.fields[1].historyNewestFirst
        assertEquals(PASSWORD_HISTORY_LIMIT, kept.size); assertEquals("pw-11", kept.first().value); assertEquals("pw-2", kept.last().value)
        val imported = Pkb2.import(sample(), "correct horse")[0]
        val edited = imported.copy(fields = imported.fields.mapIndexed { i, f -> if (i == 4) f.copy(value = "Pw-two-3!") else f }).recordingPasswordChanges(imported, at)
        assertEquals(listOf("Pw-two-2!", "Old-pw-0!", "Older-pw-9!"), edited.fields[4].historyNewestFirst.map { it.value })
    }

    @Test fun wrongPasswordAndTamperingAreRejected() {
        assertThrows(AuthenticationFailure::class.java) { Pkb2.import(sample(), "wrong password") }
        val tampered = sample(); tampered[tampered.size - 40] = (tampered[tampered.size - 40].toInt() xor 1).toByte()
        assertThrows(IllegalArgumentException::class.java) { Pkb2.import(tampered, "correct horse") }
        assertThrows(IllegalArgumentException::class.java) { Pkb2.import(sample().copyOf(100), "correct horse") }
        assertFalse(Pkb2.isPkb2("QVAULT01".toByteArray())); assertTrue(Pkb2.isPkb2(sample()))
    }

    // Optional: PASSVAULT_TEST_PKB2=/path/file.pkb2 PASSVAULT_TEST_PKB2_PASSWORD=... ./gradlew :app:testDebugUnitTest (contents are never printed).
    @Test fun localPkb2File() {
        val path = System.getenv("PASSVAULT_TEST_PKB2") ?: return
        val records = Pkb2.import(java.io.File(path).readBytes(), System.getenv("PASSVAULT_TEST_PKB2_PASSWORD").orEmpty())
        assertTrue(records.isNotEmpty())
        println("Imported ${records.size} records; field kinds per record: ${records.map { r -> r.fields.map { it.kind.name } }}")
        println("History (kind@index: change times, newest first): " + records.flatMap { r -> r.fields.mapIndexedNotNull { i, f -> if (f.history.isEmpty()) null else "${f.kind.name}@$i: ${f.historyNewestFirst.map { it.changedAtEpochSeconds }}" } })
        println("Record updatedAt: ${records.map { it.updatedAt }}")
    }
}
