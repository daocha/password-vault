package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.YearMonth

class CardsTest {
    @Test fun brandFromLeadingDigits() {
        assertEquals("Visa", Cards.brand("4111 1111 1111 1111"))
        assertEquals("Mastercard", Cards.brand("5500000000000004"))
        assertEquals("Mastercard", Cards.brand("2221000000000009"))
        assertEquals("American Express", Cards.brand("378282246310005"))
        assertEquals("Discover", Cards.brand("6011111111111117"))
        assertEquals("JCB", Cards.brand("3530111333300000"))
        assertEquals("UnionPay", Cards.brand("6200000000000005"))
        assertNull(Cards.brand("9999"))
        assertNull(Cards.brand(""))
    }
    @Test fun formattingAndSummary() {
        assertEquals("4111 1111 1111 1111", Cards.formatted("4111111111111111"))
        assertEquals("3782 822463 10005", Cards.formatted("378282246310005"))
        assertEquals("not a number", Cards.formatted("not a number"))
        val card = VaultRecord(type = RecordType.card, fields = defaultFields(RecordType.card).map { if (it.label == CARD_NUMBER_LABEL) it.copy(value = "4111 1111 1111 1234") else it })
        assertEquals("Visa •••• 1234", card.cardSummary)
        assertEquals("", VaultRecord(type = RecordType.card, fields = defaultFields(RecordType.card)).cardSummary)
    }
    @Test fun expiryFormats() {
        assertEquals(YearMonth.of(2027, 3), Cards.parseExpiry("03/27"))
        assertEquals(YearMonth.of(2027, 3), Cards.parseExpiry("3/2027"))
        assertEquals(YearMonth.of(2027, 3), Cards.parseExpiry("2027-03"))
        assertEquals(YearMonth.of(2027, 3), Cards.parseExpiry("0327"))
        assertEquals(YearMonth.of(1999, 12), Cards.parseExpiry("121999"))
        assertEquals(YearMonth.of(2027, 12), Cards.parseExpiry(" 12 / 27 "))
        assertNull(Cards.parseExpiry("13/27"))
        assertNull(Cards.parseExpiry("soon"))
    }
    @Test fun cardInputStoresDigitsAndShowsSeparators() {
        val number = CardInput.number; val expiry = CardInput.expiry
        assertEquals("5241", number.clean("5241")); assertEquals("5241 ", number.formatted("5241"))
        assertEquals("5241 0002 1", number.formatted(number.clean("5241 0002 1")))
        assertEquals("4111 1111 1111 1111", number.formatted("4111111111111111")) // No trailing space on a complete card.
        assertEquals("4111 1111 1111 1111 111", number.formatted(number.clean("4111-1111-1111-1111-1119")))
        assertEquals("3782 822463 10005", number.formatted("378282246310005"))
        assertEquals("02/", expiry.formatted(expiry.clean("02"))); assertEquals("02/26", expiry.formatted(expiry.clean("02/26")))
        assertEquals("1", expiry.clean("1")); assertEquals("03", expiry.clean("3")); assertEquals("", expiry.clean(""))
        assertEquals("12/1999", expiry.formatted(expiry.clean("12/1999")))
        // Values saved before this, or imported, are edited as their digits; anything else stays plain text.
        assertEquals("4111111111111234", number.digits("4111 1111 1111 1234")); assertNull(number.digits("ask the bank"))
        assertEquals("0327", expiry.digits("03/27")); assertEquals("0327", expiry.digits("2027-03")); assertNull(expiry.digits("soon"))
        assertEquals("03/27", Cards.formattedExpiry("0327")); assertEquals("03/27", Cards.formattedExpiry("03/27")); assertEquals("soon", Cards.formattedExpiry("soon")); assertEquals("202712", Cards.formattedExpiry("202712"))
        val stored = VaultRecord(type = RecordType.card, fields = defaultFields(RecordType.card).map { if (it.label == CARD_EXPIRY_LABEL) it.copy(value = "0226") else it })
        assertTrue("found as shown", stored.matches("02/26")); assertTrue(stored.matches("0226"))
        assertEquals(java.time.LocalDate.of(2026, 2, 28), VaultRecord(type = RecordType.card, fields = defaultFields(RecordType.card).map { if (it.label == CARD_EXPIRY_LABEL) it.copy(value = "0226") else it }).expiryDate)
    }
    @Test fun expiryStateFromReminderOrCard() {
        val today = LocalDate.of(2026, 10, 25)
        assertEquals(ExpiryState.none, VaultRecord().expiryState(today))
        assertEquals(ExpiryState.expired, VaultRecord(expires = "2026-10-24").expiryState(today))
        assertEquals(ExpiryState.soon, VaultRecord(expires = "2026-10-25").expiryState(today))
        assertEquals(ExpiryState.soon, VaultRecord(expires = "2026-11-24").expiryState(today))
        assertEquals(ExpiryState.ok, VaultRecord(expires = "2026-11-25").expiryState(today))
        // A card is valid through the last day of its expiry month.
        fun card(expiry: String) = VaultRecord(type = RecordType.card, fields = defaultFields(RecordType.card).map { if (it.label == CARD_EXPIRY_LABEL) it.copy(value = expiry) else it })
        assertEquals(LocalDate.of(2026, 10, 31), card("10/26").expiryDate)
        assertEquals(ExpiryState.soon, card("10/26").expiryState(today))
        assertEquals(ExpiryState.expired, card("09/26").expiryState(today))
        assertEquals(ExpiryState.ok, card("01/28").expiryState(today))
        // Logins ignore a field that happens to be labelled like a card's.
        assertNull(VaultRecord(fields = listOf(VaultField(kind = FieldKind.username, label = CARD_EXPIRY_LABEL, value = "01/20"))).expiryDate)
    }
    @Test fun newTypesRoundTripAndStayOutOfCsv() {
        val card = VaultRecord(name = "Bank", type = RecordType.card, fields = defaultFields(RecordType.card), expires = "2027-01-31")
        val note = VaultRecord(name = "Wi-Fi", type = RecordType.note, fields = defaultFields(RecordType.note))
        val login = VaultRecord(name = "Site")
        val restored = Records.decode(Records.encode(listOf(card, note, login)))
        assertEquals(listOf(card, note, login), restored)
        assertFalse(org.json.JSONObject(login.json().toString()).has("expires"))
        assertThrows(IllegalArgumentException::class.java) { VaultRecord.from(card.json().put("expires", "next year")) }
        assertEquals(listOf("Site"), VaultCSV.importRecords(VaultCSV.exportRecords(restored)).map { it.name })
        assertEquals(RecordType.login, RecordType.card.tab); assertEquals(RecordType.login, RecordType.note.tab); assertEquals(RecordType.seed, RecordType.seed.tab)
    }
    @Test fun cardNumberChangesAreKeptInHistory() {
        val before = VaultRecord(type = RecordType.card, fields = defaultFields(RecordType.card).map { if (it.label == CARD_NUMBER_LABEL) it.copy(value = "4111111111111111") else it })
        val after = before.copy(fields = before.fields.map { if (it.label == CARD_NUMBER_LABEL) it.copy(value = "4000056655665556") else it }).recordingPasswordChanges(before)
        assertEquals(listOf("4111111111111111"), after.fields.first { it.label == CARD_NUMBER_LABEL }.history.map { it.value })
        val spaced = before.copy(fields = before.fields.map { if (it.label == CARD_NUMBER_LABEL) it.copy(value = "4111 1111 1111 1111") else it })
        assertTrue("same number without spaces", before.recordingPasswordChanges(spaced).fields.first { it.label == CARD_NUMBER_LABEL }.history.isEmpty())
    }
}
