import Foundation

/// The well-known service a record belongs to, or nil. The website (or app name) is tried first, then the record name. A value matches when
/// it is a brand's name ("Spotify", "spotify") or a URL/domain on the brand's domain, subdomains included ("https://open.spotify.com/x").
/// Names must match exactly after dropping case and punctuation and a trailing "bank", "login", "account", "online", "app", "wallet" or "exchange", so "Charles Schwab Bank"
/// matches but "Spotify family plan" and "Apple pie recipes" do not. A Chinese bank name of three or more characters also matches inside a longer
/// name, so "中國農業銀行" finds 農業銀行.
public func findBrand(website: String, name: String) -> Brand? {
    for value in [website, name] { if let brand = matchBrand(value) { return brand } }
    return nil
}

func brandHost(_ value: String) -> String? {
    var s = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.isEmpty || s.contains(where: \.isWhitespace) { return nil }
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
    for separator: Character in ["/", "?", "#"] { s = String(s.split(separator: separator, omittingEmptySubsequences: false).first ?? "") }
    s = String(s.split(separator: "@", omittingEmptySubsequences: false).last ?? "")
    s = String(s.split(separator: ":", omittingEmptySubsequences: false).first ?? "")
    if s.hasPrefix("www.") { s.removeFirst(4) }
    while s.hasSuffix(".") { s.removeLast() }
    return s.contains(".") ? s : nil
}

private func matchBrand(_ value: String) -> Brand? {
    // The most specific domain wins, so wallet.coinbase.com finds Coinbase Wallet rather than Coinbase.
    if let host = brandHost(value) {
        func specificity(_ b: Brand) -> Int { b.domains.filter { host == $0 || host.hasSuffix("." + $0) }.map(\.count).max() ?? 0 }
        if let b = allBrands.max(by: { specificity($0) < specificity($1) }), specificity(b) > 0 { return b }
    }
    let n = String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    if n.isEmpty { return nil }
    if let b = allBrands.first(where: { $0.names.contains(n) }) { return b }
    for suffix in ["bank", "banking", "login", "account", "online", "app", "wallet", "exchange"] where n.count > suffix.count && n.hasSuffix(suffix) {
        let stem = String(n.dropLast(suffix.count))
        if let b = allBrands.first(where: { $0.names.contains(stem) }) { return b }
    }
    func isCJK(_ c: Character) -> Bool { (c.unicodeScalars.first?.value ?? 0) > 0x2E80 }
    if n.contains(where: isCJK) { return allBrands.first { b in b.names.contains { $0.count >= 3 && $0.contains(where: isCJK) && n.contains($0) } } }
    return nil
}
