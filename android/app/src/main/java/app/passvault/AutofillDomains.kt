package app.passvault

import java.net.IDN
import java.net.URI
import java.text.Normalizer

/** Security domain matching for autofill. Logo/name guessing deliberately does not take part in this boundary. */
internal object AutofillDomains {
    private class Rules(val exact: Set<String>, val wildcard: Set<String>, val exceptions: Set<String>)
    /** Null if the bundled list cannot be read on this phone (an older IDN table, say): then no site matches, rather than a crash. */
    private val rules: Rules? by lazy { runCatching { loadRules() }.getOrNull() }
    private fun loadRules(): Rules {
        val exact = HashSet<String>(); val wildcard = HashSet<String>(); val exceptions = HashSet<String>()
        AutofillDomains::class.java.getResourceAsStream("/public_suffix_list.dat")!!.bufferedReader().useLines { lines ->
            lines.map { it.substringBefore("//").trim() }.filter { it.isNotEmpty() }.forEach { rule ->
                when {
                    rule.startsWith("!.") -> error("Invalid public suffix rule")
                    rule.startsWith('!') -> exceptions += ascii(rule.drop(1)) ?: error("Invalid public suffix exception")
                    rule.startsWith("*.") -> wildcard += ascii(rule.drop(2)) ?: error("Invalid public suffix wildcard")
                    else -> exact += ascii(rule) ?: error("Invalid public suffix rule")
                }
            }
        }
        return Rules(exact, wildcard, exceptions)
    }

    /** A URL or bare host, with no user info, backslash, unusual scheme, invalid port, or ambiguous numeric address. Never resolves DNS. */
    fun host(value: String): String? = runCatching {
        val text = value.trim()
        if (text.isEmpty() || text.length > 8192 || text.any { it.isWhitespace() || it.isISOControl() } || '\\' in text) return null
        val uri = URI(when { "://" in text -> text; text.count { it == ':' } > 1 && !text.startsWith('[') -> "https://[$text]"; else -> "https://$text" })
        if (uri.scheme.lowercase() !in setOf("https", "http") || uri.rawUserInfo != null) return null
        val authority = uri.rawAuthority ?: return null
        if ('@' in authority || '%' in authority) return null
        val name: String
        val port: String?
        if (authority.startsWith('[')) {
            val end = authority.indexOf(']')
            if (end < 0) return null
            name = authority.substring(1, end)
            val rest = authority.substring(end + 1)
            if (rest.isNotEmpty() && !rest.startsWith(':')) return null
            port = rest.takeIf { it.isNotEmpty() }?.drop(1)
            // URI validates bracketed IPv6 literals without doing a DNS lookup; retain the whole literal for exact comparison.
            if (uri.host == null || ':' !in name) return null
        } else {
            if (authority.count { it == ':' } > 1) return null
            name = authority.substringBefore(':')
            port = authority.takeIf { ':' in it }?.substringAfter(':')
        }
        if (port != null && (port.isEmpty() || port.any { it !in '0'..'9' } || port.toIntOrNull() !in 1..65535)) return null
        if (':' in name) return name.lowercase()
        val normalized = ascii(name) ?: return null
        if (normalized.all { it in '0'..'9' || it == '.' }) {
            val parts = normalized.split('.')
            if (parts.size != 4 || parts.any { it.isEmpty() || (it.length > 1 && it.startsWith('0')) || it.toIntOrNull() !in 0..255 }) return null
        } else {
            val last = normalized.substringAfterLast('.')
            // Browsers interpret legacy numeric/hex hosts as IPv4 addresses; never guess their address here.
            if (last.all { it in '0'..'9' } || (last.startsWith("0x") && last.drop(2).all { it in "0123456789abcdef" })) return null
        }
        normalized
    }.getOrNull()

    /** Registrable domain using the complete bundled PSL, including private hosting domains; null for a suffix alone. */
    fun registrable(host: String): String? {
        if (':' in host || host.all { it in '0'..'9' || it == '.' }) return host
        val rules = rules ?: return null
        val labels = host.split('.')
        var suffixSize = 1 // PSL's implicit '*' rule.
        for (i in labels.indices) {
            val suffix = labels.drop(i).joinToString(".")
            if (suffix in rules.exceptions) return labels.takeLast(labels.size - i).joinToString(".")
            if (suffix in rules.exact) suffixSize = maxOf(suffixSize, labels.size - i)
            if (i > 0 && suffix in rules.wildcard) suffixSize = maxOf(suffixSize, labels.size - i + 1)
        }
        return labels.takeIf { it.size > suffixSize }?.takeLast(suffixSize + 1)?.joinToString(".")
    }

    fun sameSite(saved: String, requested: String): Boolean {
        val left = host(saved) ?: return false
        val right = host(requested) ?: return false
        return registrable(left)?.let { it == registrable(right) } == true
    }

    private fun ascii(value: String): String? = runCatching {
        // IDN also normalizes the Unicode full-stop variants before label validation.
        val flags = IDN.USE_STD3_ASCII_RULES or IDN.ALLOW_UNASSIGNED // The PSL contains scripts added after Java's IDNA2003 tables.
        val text = IDN.toASCII(value, flags).lowercase().removeSuffix(".")
        // Java's IDNA2003 mapping collapses e.g. faß.de into the distinct IDNA2008 site fass.de. Refuse lossy Unicode mappings.
        if (value.any { it.code > 127 }) {
            val original = Normalizer.normalize(value.replace('\u3002', '.').replace('\uFF0E', '.').replace('\uFF61', '.'), Normalizer.Form.NFC).lowercase().removeSuffix(".")
            if (original != Normalizer.normalize(IDN.toUnicode(text, flags), Normalizer.Form.NFC).lowercase()) return null
        }
        text.takeIf { it.isNotEmpty() && it.length <= 253 && it.split('.').all { label -> label.isNotEmpty() && label.length <= 63 } }
    }.getOrNull()
}
