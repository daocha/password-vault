package app.passvault

import java.time.LocalDate
import java.time.YearMonth

const val CARD_HOLDER_LABEL = "Cardholder"
const val CARD_NUMBER_LABEL = "Card number"
const val CARD_EXPIRY_LABEL = "Expiry date"
const val CARD_CODE_LABEL = "Security code"
const val CARD_PIN_LABEL = "PIN"
/** Card fields typed on a number pad; the password generator is not offered for them. */
val CARD_NUMERIC_LABELS = setOf(CARD_NUMBER_LABEL, CARD_CODE_LABEL, CARD_PIN_LABEL)

/** Fields a new record of [type] starts with. Labels are stored in English and shown translated (see `displayLabel`). */
fun defaultFields(type: RecordType): List<VaultField> = when (type) {
    RecordType.card -> listOf(VaultField(kind = FieldKind.username, label = CARD_HOLDER_LABEL), VaultField(kind = FieldKind.password, label = CARD_NUMBER_LABEL),
        VaultField(kind = FieldKind.username, label = CARD_EXPIRY_LABEL), VaultField(kind = FieldKind.password, label = CARD_CODE_LABEL),
        VaultField(kind = FieldKind.password, label = CARD_PIN_LABEL), VaultField(kind = FieldKind.note, label = "Notes"))
    RecordType.note -> listOf(VaultField(kind = FieldKind.note, label = "Notes"))
    RecordType.seed, RecordType.totp -> emptyList()
    RecordType.login -> VaultRecord().fields
}

object Cards {
    /** The card network for a number, from its leading digits, or null when unknown. */
    fun brand(number: String): String? {
        val digits = number.filter(Char::isDigit)
        if (digits.length < 2) return null
        fun prefix(n: Int) = digits.take(n).toIntOrNull() ?: -1
        return when {
            digits.startsWith("4") -> "Visa"
            prefix(2) in 51..55 || (digits.length >= 4 && prefix(4) in 2221..2720) -> "Mastercard"
            prefix(2) == 34 || prefix(2) == 37 -> "American Express"
            digits.startsWith("6011") || digits.startsWith("65") || (digits.length >= 3 && prefix(3) in 644..649) -> "Discover"
            digits.length >= 4 && prefix(4) in 3528..3589 -> "JCB"
            digits.startsWith("62") -> "UnionPay"
            prefix(2) == 36 || prefix(2) == 38 || (digits.length >= 3 && prefix(3) in 300..305) -> "Diners Club"
            else -> null
        }
    }
    /** Digits in groups of four (American Express: 4-6-5), for display only. */
    fun formatted(number: String): String {
        val digits = number.filter(Char::isDigit)
        if (digits.length < 8 || digits.length != number.count { !it.isWhitespace() && it != '-' }) return number
        val groups = if (brand(digits) == "American Express" && digits.length == 15) listOf(4, 6, 5) else List((digits.length + 3) / 4) { 4 }
        val out = mutableListOf<String>(); var i = 0
        for (size in groups) { if (i >= digits.length) break; out += digits.substring(i, minOf(digits.length, i + size)); i += size }
        return out.joinToString(" ")
    }
    fun lastFour(number: String) = number.filter(Char::isDigit).takeLast(4)
    /** Reads `MM/YY`, `MM/YYYY`, `MM-YY`, `YYYY-MM` or `MMYY`, as printed on cards and exported by other managers. */
    fun parseExpiry(text: String): YearMonth? {
        val t = text.trim()
        Regex("""^(\d{4})[-/.](\d{1,2})$""").find(t)?.let { m -> return yearMonth(m.groupValues[1].toInt(), m.groupValues[2].toInt()) }
        Regex("""^(\d{1,2})\s*[-/.]\s*(\d{2}|\d{4})$""").find(t)?.let { m -> return yearMonth(year(m.groupValues[2]), m.groupValues[1].toInt()) }
        Regex("""^(\d{2})(\d{2})$""").find(t)?.let { m -> return yearMonth(year(m.groupValues[2]), m.groupValues[1].toInt()) }
        return null
    }
    private fun year(text: String) = if (text.length == 2) 2000 + text.toInt() else text.toInt()
    private fun yearMonth(year: Int, month: Int) = if (month in 1..12 && year in 1900..2999) YearMonth.of(year, month) else null
}

val VaultRecord.cardNumber: String get() = fields.firstOrNull { it.label == CARD_NUMBER_LABEL }?.value.orEmpty()
/** "Visa •••• 1234", or just the last four digits when the network is unknown. */
val VaultRecord.cardSummary: String get() {
    val last = Cards.lastFour(cardNumber); if (last.isEmpty()) return ""
    return listOfNotNull(Cards.brand(cardNumber), "•••• $last").joinToString(" ")
}

object Expiry {
    /** Records expiring within this many days count as "expiring soon". */
    const val SOON_DAYS = 30L
    fun parseDate(text: String): LocalDate? = runCatching { LocalDate.parse(text) }.getOrNull()
}
/** The date this record needs attention: its reminder date, else (cards) the last day of the card's expiry month. */
val VaultRecord.expiryDate: LocalDate? get() = Expiry.parseDate(expires)
    ?: if (type == RecordType.card) fields.firstOrNull { it.label == CARD_EXPIRY_LABEL }?.value?.let(Cards::parseExpiry)?.atEndOfMonth() else null
enum class ExpiryState { none, ok, soon, expired }
fun VaultRecord.expiryState(today: LocalDate = LocalDate.now()): ExpiryState {
    val date = expiryDate ?: return ExpiryState.none
    return when { date.isBefore(today) -> ExpiryState.expired; !date.isAfter(today.plusDays(Expiry.SOON_DAYS)) -> ExpiryState.soon; else -> ExpiryState.ok }
}
