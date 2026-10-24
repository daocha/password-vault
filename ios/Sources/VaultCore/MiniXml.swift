import Foundation

/// One XML element: attributes, child elements in document order, and its own text (CDATA included, entities decoded).
public final class XmlElement {
    public let name: String
    public let attributes: [String: String]
    public var children = [XmlElement]()
    public var text = ""
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    public func child(_ name: String) -> XmlElement? { children.first { $0.name == name } }
    public func all(_ name: String) -> [XmlElement] { children.filter { $0.name == name } }
    /// This element and every descendant, in document order.
    public func walk(_ visit: (XmlElement) throws -> Void) rethrows {
        var stack = [self]
        while let e = stack.popLast() { try visit(e); stack.append(contentsOf: e.children.reversed()) }
    }
}

/// A small, strict XML reader for KeePass databases, KeePass XML exports and key files; the same as Android's. It never fetches or
/// expands anything: a DOCTYPE (and with it every external or custom entity) is refused, so XXE and entity-expansion attacks cannot apply.
public enum MiniXml {
    static let maxDepth = 256
    public static func parse(_ input: Data) throws -> XmlElement {
        var s = [UInt8](input)
        if s.starts(with: [0xEF, 0xBB, 0xBF]) { s.removeFirst(3) }
        let damaged = VaultError.invalid("Damaged XML.")
        var i = 0, stack = [XmlElement](), root: XmlElement?
        func starts(_ marker: String) -> Bool { let m = Array(marker.utf8); return i + m.count <= s.count && Array(s[i..<i + m.count]) == m }
        func find(_ marker: String, from: Int) -> Int? {
            let m = Array(marker.utf8); var j = from
            while j + m.count <= s.count { if s[j] == m[0] && Array(s[j..<j + m.count]) == m { return j }; j += 1 }
            return nil
        }
        func isNameByte(_ c: UInt8) -> Bool { c >= 0x80 || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D || c == 0x2E || c == 0x3A }
        func name() throws -> String { let start = i; while i < s.count && isNameByte(s[i]) { i += 1 }; guard i > start else { throw damaged }; return String(decoding: s[start..<i], as: UTF8.self) }
        func spaces() { while i < s.count && [0x20, 0x09, 0x0A, 0x0D].contains(s[i]) { i += 1 } }
        func skipPast(_ marker: String) throws { guard let end = find(marker, from: i) else { throw damaged }; i = end + marker.utf8.count }
        while i < s.count {
            if starts("<?") { try skipPast("?>") }
            else if starts("<!--") { try skipPast("-->") }
            else if starts("<![CDATA[") {
                guard let end = find("]]>", from: i), let top = stack.last else { throw damaged }
                top.text += String(decoding: s[(i + 9)..<end], as: UTF8.self); i = end + 3
            }
            else if starts("<!") { throw VaultError.invalid("XML with a DOCTYPE is not accepted.") }
            else if starts("</") {
                i += 2; let n = try name(); spaces()
                guard i < s.count, s[i] == 0x3E, let top = stack.last, top.name == n else { throw damaged }
                i += 1; stack.removeLast()
            }
            else if s[i] == 0x3C {
                i += 1; let n = try name(); var attributes = [String: String]()
                while true {
                    spaces(); guard i < s.count else { throw damaged }
                    if s[i] == 0x3E || starts("/>") { break }
                    let key = try name(); spaces(); guard i < s.count, s[i] == 0x3D else { throw damaged }; i += 1; spaces()
                    guard i < s.count, s[i] == 0x22 || s[i] == 0x27 else { throw damaged }
                    let quote = s[i]; var end = i + 1; while end < s.count && s[end] != quote { end += 1 }; guard end < s.count else { throw damaged }
                    attributes[key] = try decode(String(decoding: s[(i + 1)..<end], as: UTF8.self)); i = end + 1
                }
                let element = XmlElement(name: n, attributes: attributes)
                if let top = stack.last { top.children.append(element) } else { guard root == nil else { throw damaged }; root = element }
                if s[i] == 0x3E { i += 1; stack.append(element); guard stack.count <= maxDepth else { throw damaged } } else { i += 2 }
            }
            else {
                var end = i; while end < s.count && s[end] != 0x3C { end += 1 }
                let text = String(decoding: s[i..<end], as: UTF8.self)
                if let top = stack.last { top.text += try decode(text) } else if !text.allSatisfy(\.isWhitespace) { throw damaged }
                i = end
            }
        }
        guard stack.isEmpty, let root else { throw damaged }
        return root
    }
    static func decode(_ text: String) throws -> String {
        guard text.contains("&") else { return text }
        var out = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";") else { throw VaultError.invalid("Damaged XML.") }
            let entity = rest[rest.index(after: amp)..<semi]
            switch entity {
            case "lt": out += "<"; case "gt": out += ">"; case "amp": out += "&"; case "quot": out += "\""; case "apos": out += "'"
            default:
                let value: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") { value = UInt32(entity.dropFirst(2), radix: 16) }
                else if entity.hasPrefix("#") { value = UInt32(entity.dropFirst(), radix: 10) }
                else { value = nil }
                guard let value, let scalar = Unicode.Scalar(value) else { throw VaultError.invalid("Damaged XML.") }
                out.unicodeScalars.append(scalar)
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }
}
