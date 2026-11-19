import Foundation

/// Security domain matching for AutoFill, as Android's `AutofillDomains`: the same bundled Public Suffix List (including private hosting
/// domains), IP addresses compared as complete literals, and malformed or ambiguous hosts refused. Never resolves DNS.
public enum AutofillDomains {
    private struct Rules { let exact: Set<String>, wildcard: Set<String>, exceptions: Set<String> }
    /// Nil if the bundled list cannot be read or one of its rules cannot be converted: then no website matches, rather than a rule being
    /// skipped (a missing suffix would make every site under it look like one site).
    private static let rules: Rules? = loadRules()
    private static func loadRules() -> Rules? {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = (line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)).trimmingCharacters(in: .whitespaces)
            if rule.isEmpty { continue }
            if rule.hasPrefix("!.") { return nil }
            if rule.hasPrefix("!") { guard let name = ascii(String(rule.dropFirst())) else { return nil }; exceptions.insert(name) }
            else if rule.hasPrefix("*.") { guard let name = ascii(String(rule.dropFirst(2))) else { return nil }; wildcard.insert(name) }
            else { guard let name = ascii(rule) else { return nil }; exact.insert(name) }
        }
        return Rules(exact: exact, wildcard: wildcard, exceptions: exceptions)
    }
    /// Whether the bundled list was read (tests check it, since a failure only stops matching).
    public static var listLoaded: Bool { rules != nil }

    /// The host of a URL or bare host name: lowercase ASCII (international names in their xn-- form), a dotted IPv4 address, or an IPv6
    /// literal. Nil for anything with user info, a backslash, another scheme, an invalid port, or an ambiguous numeric address.
    public static func host(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= 8192, !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let full: String
        if let range = text.range(of: "://") {
            guard ["https", "http"].contains(text[..<range.lowerBound].lowercased()) else { return nil }
            full = text
        } else if text.filter({ $0 == ":" }).count > 1 && !text.hasPrefix("[") { full = "https://[\(text)]" } else { full = "https://\(text)" }
        let rest = full[full.range(of: "://")!.upperBound...]
        let authority = String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains("%") else { return nil }
        let name: String, port: Substring?
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return nil }
            name = String(authority[authority.index(after: authority.startIndex)..<end])
            let after = authority[authority.index(after: end)...]
            guard after.isEmpty || after.hasPrefix(":") else { return nil }
            port = after.isEmpty ? nil : after.dropFirst()
            // A bracketed address must be a valid IPv6 literal; it is compared as written.
            var address = in6_addr()
            guard name.contains(":"), inet_pton(AF_INET6, name, &address) == 1 else { return nil }
        } else {
            guard authority.filter({ $0 == ":" }).count <= 1 else { return nil }
            let parts = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            name = String(parts[0]); port = parts.count > 1 ? parts[1] : nil
        }
        if let port {
            guard !port.isEmpty, port.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(port), (1...65535).contains(number) else { return nil }
        }
        if name.contains(":") { return name.lowercased() }
        guard let normalized = ascii(name) else { return nil }
        if normalized.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }) {
            let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && !($0.count > 1 && $0.hasPrefix("0")) && (Int($0).map { (0...255).contains($0) } ?? false) }) else { return nil }
        } else {
            // Browsers read legacy numeric and hex hosts as IPv4 addresses; never guess their address here.
            let last = normalized.split(separator: ".").last.map(String.init) ?? ""
            if last.allSatisfy({ ("0"..."9").contains($0) }) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) }) { return nil }
        }
        return normalized
    }

    /// The registrable domain (the part one owner controls) using the bundled list; the host itself for an IP address; nil for a public
    /// suffix on its own.
    public static func registrable(_ host: String) -> String? {
        if host.contains(":") || host.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }) { return host }
        guard let rules else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var suffixSize = 1 // the list's implicit "*" rule
        for i in labels.indices {
            let suffix = labels[i...].joined(separator: ".")
            if rules.exceptions.contains(suffix) { return labels[i...].joined(separator: ".") }
            if rules.exact.contains(suffix) { suffixSize = max(suffixSize, labels.count - i) }
            if i > 0 && rules.wildcard.contains(suffix) { suffixSize = max(suffixSize, labels.count - i + 1) }
        }
        return labels.count > suffixSize ? labels.suffix(suffixSize + 1).joined(separator: ".") : nil
    }

    /// Whether a saved website and the site asking belong to the same registrable domain.
    public static func sameSite(_ saved: String, _ requested: String) -> Bool {
        guard let left = host(saved), let right = host(requested), let site = registrable(left) else { return false }
        return site == registrable(right)
    }

    /// A host name as lowercase ASCII, one trailing dot removed: an international name in its IDNA (xn--) form, as Safari uses it.
    /// Nil unless every label is letters, digits and inner hyphens of 1–63 characters, 253 in all.
    static func ascii(_ value: String) -> String? {
        var text = value
        if text.unicodeScalars.contains(where: { !$0.isASCII }) {
            // The ideographic and full-width full stops separate labels too.
            text = text.replacingOccurrences(of: "\u{3002}", with: ".").replacingOccurrences(of: "\u{FF0E}", with: ".").replacingOccurrences(of: "\u{FF61}", with: ".")
            guard let encoded = URLComponents(string: "https://" + text)?.encodedHost, !encoded.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
            text = encoded
        }
        text = text.lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty, text.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }) else { return nil }
        return text
    }
}

/// Which logins to offer for a website, as Android's `AutofillMatch`. A match only puts a login first: every fill still asks the user to
/// confirm where it goes.
public enum AutofillMatch {
    /// Logins with a username or password to fill: not cards, notes, seed phrases or 2FA keys.
    public static func candidates(_ records: [VaultRecord]) -> [VaultRecord] {
        records.filter { record in record.isLogin && record.fields.contains { ($0.kind == .password || $0.kind == .username) && !$0.value.isEmpty } }
    }
    /// The sites the system says are asking (a web page's address, or the domains an app is associated with), as hosts. Unreadable ones are dropped.
    public static func sites(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap(AutofillDomains.host).filter { seen.insert($0).inserted }
    }
    public static func suggests(_ record: VaultRecord, sites: [String]) -> Bool {
        let website = record.website.trimmingCharacters(in: .whitespaces)
        return !website.isEmpty && sites.contains { AutofillDomains.sameSite(website, $0) }
    }
    /// Favorites first, then by name, as Android lists them.
    public static func ordered(_ records: [VaultRecord]) -> [VaultRecord] {
        records.sorted { ($0.favorite ? 0 : 1, $0.name.lowercased()) < ($1.favorite ? 0 : 1, $1.name.lowercased()) }
    }
    /// What the picker shows: with no search, the suggested logins (or all of them when none matches); with a search, every match,
    /// suggested ones first.
    public static func shown(_ logins: [VaultRecord], sites: [String], query: String) -> (records: [VaultRecord], suggested: Bool) {
        shown(logins, suggested: suggestedIDs(logins, sites: sites), query: query)
    }
    /// The logins `suggests` puts first, worked out once when the vault opens rather than on every keystroke of a search.
    public static func suggestedIDs(_ logins: [VaultRecord], sites: [String]) -> Set<String> { Set(logins.filter { suggests($0, sites: sites) }.map(\.id)) }
    public static func shown(_ logins: [VaultRecord], suggested ids: Set<String>, query: String) -> (records: [VaultRecord], suggested: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let suggested = ordered(logins.filter { ids.contains($0.id) })
            return suggested.isEmpty ? (ordered(logins), false) : (suggested, true)
        }
        let found = ordered(logins.filter { $0.matches(trimmed) })
        return (found.filter { ids.contains($0.id) } + found.filter { !ids.contains($0.id) }, false)
    }
    public static func username(_ record: VaultRecord) -> String? { record.fields.first { $0.kind == .username && !$0.value.isEmpty }?.value }
    public static func password(_ record: VaultRecord) -> String? { record.fields.first { $0.kind == .password && !$0.value.isEmpty }?.value }
}

/// What iOS may show above the keyboard for each login when the user turns on "Show logins above the keyboard": the login's site (its
/// registrable domain), its username (the entry's name when it has none) and the record's ID. Never a password, a note or any other
/// field. iOS offers PassVault on a page only when it holds one of these for that site, so the AutoFill settings list the logins left
/// out and why (`skipped`).
public enum AutofillIdentities {
    public struct Entry: Equatable {
        public let domain: String, user: String, recordID: String
        public init(domain: String, user: String, recordID: String) { self.domain = domain; self.user = user; self.recordID = recordID }
    }
    /// Why a login is not given to iOS. The raw values are the settings' text (localization keys).
    public enum Skip: String, CaseIterable {
        case noWebsite = "Not shown, no website: %@"
        case badWebsite = "Not shown, website not recognized: %@"
        case noPassword = "Not shown, no password: %@"
    }
    public static func entries(_ records: [VaultRecord]) -> [Entry] {
        AutofillMatch.candidates(records).compactMap { record in
            guard skip(record) == nil, let domain = AutofillDomains.host(record.website).flatMap(AutofillDomains.registrable) else { return nil }
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return Entry(domain: domain, user: AutofillMatch.username(record) ?? (name.isEmpty ? domain : name), recordID: record.id)
        }
    }
    public static func skip(_ record: VaultRecord) -> Skip? {
        if record.website.trimmingCharacters(in: .whitespaces).isEmpty { return .noWebsite }
        if AutofillDomains.host(record.website).flatMap(AutofillDomains.registrable) == nil { return .badWebsite }
        if AutofillMatch.password(record) == nil { return .noPassword }
        return nil
    }
    public struct Skipped: Equatable {
        public let reason: Skip, names: [String]
        public init(reason: Skip, names: [String]) { self.reason = reason; self.names = names }
    }
    /// The logins left out, by reason, as entry names sorted as the picker lists them.
    public static func skipped(_ records: [VaultRecord]) -> [Skipped] {
        let logins = AutofillMatch.ordered(AutofillMatch.candidates(records))
        return Skip.allCases.compactMap { reason in
            let names = logins.filter { skip($0) == reason }.map(\.name)
            return names.isEmpty ? nil : Skipped(reason: reason, names: names)
        }
    }
}
