package app.passvault

/** Wallet private keys (hex, WIF, or any other single-token format). Only light sanity checks: the key is stored exactly as entered. */
object PrivateKey {
    private val hex = Regex("(0x)?[0-9a-fA-F]{64}")
    private val base58 = Regex("[1-9A-HJ-NP-Za-km-z]{51,52}")
    /** Null when [text] looks like a usable key, otherwise the reason. */
    fun problem(text: String): UiText? = when {
        text.isBlank() -> UiText(R.string.seed_err_key_empty)
        text.trim().any { it.isWhitespace() } -> UiText(R.string.seed_err_key_spaces)
        text.trim().length < 16 -> UiText(R.string.seed_err_key_short)
        else -> null
    }
    /** Human-readable format guess for a key that passed [problem]. */
    fun format(text: String): UiText = text.trim().let { when {
        hex.matches(it) -> UiText(R.string.seed_fmt_hex)
        base58.matches(it) -> UiText(R.string.seed_fmt_wif)
        else -> UiText(R.string.seed_fmt_unknown)
    } }
}
