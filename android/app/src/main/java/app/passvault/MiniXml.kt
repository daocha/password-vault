package app.passvault

/** One XML element: attributes, child elements in document order, and its own text (CDATA included, entities decoded). */
class XmlElement(val name: String, val attributes: Map<String, String>) {
    val children = mutableListOf<XmlElement>()
    internal val textBuilder = StringBuilder()
    var text: String
        get() = textBuilder.toString()
        set(value) { textBuilder.setLength(0); textBuilder.append(value) }
    fun child(name: String) = children.firstOrNull { it.name == name }
    fun all(name: String) = children.filter { it.name == name }
    /** This element and every descendant, in document order. */
    fun walk(visit: (XmlElement) -> Unit) {
        val stack = ArrayDeque<XmlElement>().apply { add(this@XmlElement) }
        while (stack.isNotEmpty()) { val e = stack.removeLast(); visit(e); for (i in e.children.indices.reversed()) stack.add(e.children[i]) }
    }
}

/**
 * A small, strict XML reader for KeePass databases, KeePass XML exports and key files. It never fetches or expands anything: a DOCTYPE
 * (and with it every external or custom entity) is refused, so XXE and entity-expansion attacks cannot apply. iOS has the same reader.
 */
object MiniXml {
    private const val MAX_DEPTH = 256
    fun parse(input: String): XmlElement {
        val s = input.removePrefix("\uFEFF"); var i = 0
        val stack = ArrayList<XmlElement>(); var root: XmlElement? = null
        fun fail(): Nothing = throw IllegalArgumentException("Damaged XML.")
        fun isNameChar(c: Char) = c.isLetterOrDigit() || c == '_' || c == '-' || c == '.' || c == ':'
        fun name(): String { val start = i; while (i < s.length && isNameChar(s[i])) i++; if (i == start) fail(); return s.substring(start, i) }
        fun spaces() { while (i < s.length && s[i].isWhitespace()) i++ }
        fun skipPast(marker: String) { val end = s.indexOf(marker, i); if (end < 0) fail(); i = end + marker.length }
        while (i < s.length) {
            when {
                s.startsWith("<?", i) -> skipPast("?>")
                s.startsWith("<!--", i) -> skipPast("-->")
                s.startsWith("<![CDATA[", i) -> {
                    val end = s.indexOf("]]>", i); if (end < 0 || stack.isEmpty()) fail()
                    stack.last().textBuilder.append(s, i + 9, end); i = end + 3
                }
                s.startsWith("<!", i) -> throw IllegalArgumentException("XML with a DOCTYPE is not accepted.")
                s.startsWith("</", i) -> {
                    i += 2; val n = name(); spaces(); if (i >= s.length || s[i] != '>' || stack.isEmpty() || stack.last().name != n) fail()
                    i++; stack.removeAt(stack.size - 1)
                }
                s[i] == '<' -> {
                    i++; val n = name(); val attributes = LinkedHashMap<String, String>()
                    while (true) {
                        spaces(); if (i >= s.length) fail()
                        if (s[i] == '>' || s.startsWith("/>", i)) break
                        val key = name(); spaces(); if (i >= s.length || s[i] != '=') fail(); i++; spaces()
                        if (i >= s.length || (s[i] != '"' && s[i] != '\'')) fail()
                        val quote = s[i]; val end = s.indexOf(quote, i + 1); if (end < 0) fail()
                        attributes[key] = decode(s.substring(i + 1, end)); i = end + 1
                    }
                    val element = XmlElement(n, attributes)
                    if (stack.isEmpty()) { if (root != null) fail(); root = element } else stack.last().children += element
                    if (s[i] == '>') { i++; stack += element; if (stack.size > MAX_DEPTH) fail() } else i += 2
                }
                else -> {
                    val end = s.indexOf('<', i).let { if (it < 0) s.length else it }
                    val text = s.substring(i, end)
                    if (stack.isEmpty()) { if (text.isNotBlank()) fail() } else stack.last().textBuilder.append(decode(text))
                    i = end
                }
            }
        }
        if (stack.isNotEmpty()) fail()
        return root ?: fail()
    }
    private fun decode(text: String): String {
        if ('&' !in text) return text
        val out = StringBuilder(); var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c != '&') { out.append(c); i++; continue }
            val end = text.indexOf(';', i); require(end > i) { "Damaged XML." }
            val entity = text.substring(i + 1, end)
            when {
                entity == "lt" -> out.append('<'); entity == "gt" -> out.append('>'); entity == "amp" -> out.append('&')
                entity == "quot" -> out.append('"'); entity == "apos" -> out.append('\'')
                entity.startsWith("#x") || entity.startsWith("#X") -> out.appendCodePoint(entity.substring(2).toIntOrNull(16)?.takeIf(Character::isValidCodePoint) ?: throw IllegalArgumentException("Damaged XML."))
                entity.startsWith("#") -> out.appendCodePoint(entity.substring(1).toIntOrNull()?.takeIf(Character::isValidCodePoint) ?: throw IllegalArgumentException("Damaged XML."))
                else -> throw IllegalArgumentException("Damaged XML.")
            }
            i = end + 1
        }
        return out.toString()
    }
}
