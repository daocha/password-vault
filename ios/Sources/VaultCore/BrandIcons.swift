import Foundation

/// The well-known service a record belongs to, or nil. The website (or app name) is tried first, then the record name. A value matches when
/// it is a brand's name ("Spotify", "spotify") or a URL/domain on the brand's domain, subdomains included ("https://open.spotify.com/x").
/// Names must match exactly after dropping case and punctuation, so "Spotify family plan" or "Apple pie recipes" do not.
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
    if let host = brandHost(value), let b = allBrands.first(where: { $0.domains.contains { host == $0 || host.hasSuffix("." + $0) } }) { return b }
    let n = String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    return n.isEmpty ? nil : allBrands.first { $0.names.contains(n) }
}
