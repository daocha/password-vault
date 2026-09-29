package app.passvault

/**
 * The well-known service a record belongs to, or null. The website (or app name) is tried first, then the record name. A value matches when
 * it is a brand's name ("Spotify", "spotify") or a URL/domain on the brand's domain, subdomains included ("https://open.spotify.com/x").
 * Names must match exactly after dropping case and punctuation, so "Spotify family plan" or "Apple pie recipes" do not.
 */
fun findBrand(website: String, name: String): Brand? = listOf(website, name).firstNotNullOfOrNull { matchBrand(it) }

private fun normalizeName(s: String) = buildString { s.lowercase().forEach { if (it.isLetterOrDigit()) append(it) } }

internal fun hostOf(value: String): String? {
    var s = value.trim().lowercase()
    if (s.isEmpty() || s.any { it.isWhitespace() }) return null
    s = s.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#').substringAfterLast('@').substringBefore(':')
    s = s.removePrefix("www.").trimEnd('.')
    return s.takeIf { '.' in it }
}

private fun matchBrand(value: String): Brand? {
    hostOf(value)?.let { host -> brands.firstOrNull { b -> b.domains.any { host == it || host.endsWith(".$it") } }?.let { return it } }
    val n = normalizeName(value)
    return if (n.isEmpty()) null else brands.firstOrNull { n in it.names }
}
