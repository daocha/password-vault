package app.passvault

/**
 * The well-known service a record belongs to, or null. The website (or app name) is tried first, then the record name. A value matches when
 * it is a brand's name ("Spotify", "spotify") or a URL/domain on the brand's domain, subdomains included ("https://open.spotify.com/x").
 * Names must match exactly after dropping case and punctuation and a trailing "bank", "login", "account", "online", "app", "wallet" or "exchange", so "Charles Schwab Bank"
 * matches but "Spotify family plan" and "Apple pie recipes" do not. A Chinese bank name of three or more characters also matches inside a longer
 * name, so "中國農業銀行" finds 農業銀行.
 */
fun findBrand(website: String, name: String): Brand? = listOf(website, name).firstNotNullOfOrNull { matchBrand(it) }

private val genericSuffixes = listOf("bank", "banking", "login", "account", "online", "app", "wallet", "exchange")

private fun normalizeName(s: String) = buildString { s.lowercase().forEach { if (it.isLetterOrDigit()) append(it) } }

internal fun hostOf(value: String): String? {
    var s = value.trim().lowercase()
    if (s.isEmpty() || s.any { it.isWhitespace() }) return null
    s = s.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#').substringAfterLast('@').substringBefore(':')
    s = s.removePrefix("www.").trimEnd('.')
    return s.takeIf { '.' in it }
}

private fun matchBrand(value: String): Brand? {
    // The most specific domain wins, so wallet.coinbase.com finds Coinbase Wallet rather than Coinbase.
    hostOf(value)?.let { host -> brands.maxByOrNull { b -> b.domains.filter { host == it || host.endsWith(".$it") }.maxOfOrNull { it.length } ?: 0 }?.takeIf { b -> b.domains.any { host == it || host.endsWith(".$it") } }?.let { return it } }
    val n = normalizeName(value)
    if (n.isEmpty()) return null
    brands.firstOrNull { n in it.names }?.let { return it }
    for (suffix in genericSuffixes) if (n.length > suffix.length && n.endsWith(suffix)) { val stem = n.removeSuffix(suffix); brands.firstOrNull { stem in it.names }?.let { return it } }
    if (n.any { it.code > 0x2E80 }) return brands.firstOrNull { b -> b.names.any { it.length >= 3 && it.any { c -> c.code > 0x2E80 } && n.contains(it) } }
    return null
}
