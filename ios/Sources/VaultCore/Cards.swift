import Foundation

public let cardHolderLabel = "Cardholder", cardNumberLabel = "Card number", cardExpiryLabel = "Expiry date", cardCodeLabel = "Security code", cardPinLabel = "PIN"
/// Card fields typed on a number pad; the password generator is not offered for them.
public let cardNumericLabels: Set<String> = [cardNumberLabel, cardCodeLabel, cardPinLabel]

extension VaultRecord {
    /// A new, empty record of `type` ("login", "card" or "note") with that type's starting fields. Labels match Android.
    public static func new(type: String) -> VaultRecord {
        var record = VaultRecord()
        switch type {
        case "card":
            record.type = "card"
            record.fields = [.init(kind: .username, label: cardHolderLabel), .init(kind: .password, label: cardNumberLabel), .init(kind: .username, label: cardExpiryLabel),
                             .init(kind: .password, label: cardCodeLabel), .init(kind: .password, label: cardPinLabel), .init(kind: .note, label: "Notes")]
        case "note":
            record.type = "note"; record.fields = [.init(kind: .note, label: "Notes")]
        default: break
        }
        return record
    }
    public var cardNumber: String { fields.first { $0.label == cardNumberLabel }?.value ?? "" }
    /// "Visa •••• 1234", or just the last four digits when the network is unknown.
    public var cardSummary: String {
        let last = Cards.lastFour(cardNumber)
        guard !last.isEmpty else { return "" }
        return [Cards.brand(cardNumber), "•••• \(last)"].compactMap { $0 }.joined(separator: " ")
    }
    /// The date this record needs attention: its reminder date, else (cards) the last day of the card's expiry month.
    public var expiryDate: DateComponents? {
        if let expires, let date = Expiry.parseDate(expires) { return date }
        guard isCard, let value = fields.first(where: { $0.label == cardExpiryLabel })?.value, let month = Cards.parseExpiry(value) else { return nil }
        return Expiry.endOfMonth(year: month.year, month: month.month)
    }
    public func expiryState(today: DateComponents = Expiry.today()) -> ExpiryState {
        guard let date = expiryDate else { return .none }
        let day = Expiry.dayNumber(date), now = Expiry.dayNumber(today)
        if day < now { return .expired }
        return day <= now + Expiry.soonDays ? .soon : .ok
    }
}

public enum ExpiryState: Sendable { case none, ok, soon, expired }

/// Calendar days as `yyyy-MM-dd`, compared without time zones (Gregorian, like Android's `LocalDate`).
public enum Expiry {
    public static let soonDays = 30
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    public static func parseDate(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let components = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }
    public static func format(_ date: DateComponents) -> String { String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0) }
    public static func today() -> DateComponents { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date()) }
    static func endOfMonth(year: Int, month: Int) -> DateComponents? {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)), let days = calendar.range(of: .day, in: .month, for: first) else { return nil }
        return DateComponents(year: year, month: month, day: days.count)
    }
    static func dayNumber(_ date: DateComponents) -> Int {
        let value = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? .distantPast
        return Int((value.timeIntervalSince1970 / 86400).rounded(.down))
    }
    /// The calendar day as a local-time `Date`, for date pickers and display.
    public static func localDate(_ date: DateComponents) -> Date? { Calendar(identifier: .gregorian).date(from: DateComponents(year: date.year, month: date.month, day: date.day)) }
    public static func components(_ date: Date) -> DateComponents { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date) }
    /// An imported date as `yyyy-MM-dd`, or "" for one outside years 1–9999 (e.g. KeePass's 9999-12-31 read east of UTC), which
    /// `parseDate` and Android would refuse, failing the whole import.
    public static func imported(_ date: Date) -> String {
        let c = components(date)
        guard let year = c.year, (1...9999).contains(year) else { return "" }
        return format(c)
    }
}

public enum Cards {
    /// The card network for a number, from its leading digits, or nil when unknown.
    public static func brand(_ number: String) -> String? {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 2 else { return nil }
        func prefix(_ n: Int) -> Int { digits.count >= n ? Int(digits.prefix(n)) ?? -1 : -1 }
        if digits.hasPrefix("4") { return "Visa" }
        if (51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)) { return "Mastercard" }
        if prefix(2) == 34 || prefix(2) == 37 { return "American Express" }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") || (644...649).contains(prefix(3)) { return "Discover" }
        if (3528...3589).contains(prefix(4)) { return "JCB" }
        if digits.hasPrefix("62") { return "UnionPay" }
        if prefix(2) == 36 || prefix(2) == 38 || (300...305).contains(prefix(3)) { return "Diners Club" }
        return nil
    }
    /// Digits in groups of four (American Express: 4-6-5), for display only.
    public static func formatted(_ number: String) -> String {
        let digits = Array(number.filter(\.isNumber))
        guard digits.count >= 8, digits.count == number.filter({ !$0.isWhitespace && $0 != "-" }).count else { return number }
        let groups = brand(String(digits)) == "American Express" && digits.count == 15 ? [4, 6, 5] : Array(repeating: 4, count: (digits.count + 3) / 4)
        var out = [String](), index = 0
        for size in groups where index < digits.count { out.append(String(digits[index..<min(digits.count, index + size)])); index += size }
        return out.joined(separator: " ")
    }
    public static func lastFour(_ number: String) -> String { String(number.filter(\.isNumber).suffix(4)) }
    /// Reads `MM/YY`, `MM/YYYY`, `MM-YY`, `YYYY-MM`, `MMYY` or `MMYYYY`, as printed on cards and exported by other managers.
    public static func parseExpiry(_ text: String) -> (year: Int, month: Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        func make(_ year: Int, _ month: Int) -> (year: Int, month: Int)? { (1...12).contains(month) && (1900...2999).contains(year) ? (year, month) : nil }
        func year(_ s: Substring) -> Int? { s.count == 2 ? Int(s).map { 2000 + $0 } : Int(s) }
        let separators = CharacterSet(charactersIn: "-/.")
        let parts = t.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
            if parts[0].count == 4, parts[1].count <= 2, let y = Int(parts[0]), let m = Int(parts[1]) { return make(y, m) }
            if parts[0].count <= 2, [2, 4].contains(parts[1].count), let m = Int(parts[0]), let y = year(Substring(parts[1])) { return make(y, m) }
            return nil
        }
        if [4, 6].contains(t.count), t.allSatisfy({ $0.isASCII && $0.isNumber }), let m = Int(t.prefix(2)), let y = year(t.dropFirst(2)) { return make(y, m) }
        return nil
    }
    /// An expiry as stored: `MMYY` for years 2000–2099, `MMYYYY` for any other (see `CardInput`).
    public static func expiryDigits(_ month: (year: Int, month: Int)) -> String {
        String(format: "%02d", month.month) + ((2000...2099).contains(month.year) ? String(format: "%02d", month.year % 100) : String(month.year))
    }
    /// `MM/YY` for a stored expiry; anything else, such as other digits ("202712"), is shown as stored.
    public static func formattedExpiry(_ value: String) -> String {
        guard let digits = CardInput.expiry.digits(value), parseExpiry(digits) != nil else { return value }
        return CardInput.expiry.formatted(digits)
    }
}

/// How a card's number and expiry date are typed; mirrors Android's `CardInput`. Only the digits are stored ("5241000212345678", "0226");
/// the editor shows the spaces or the slash as the user types, so they are never part of the value.
public enum CardInput: Sendable {
    case number, expiry
    public static func of(_ label: String) -> CardInput? { label == cardNumberLabel ? .number : label == cardExpiryLabel ? .expiry : nil }
    var maxDigits: Int { self == .number ? 19 : 6 }
    var separator: Character { self == .number ? " " : "/" }
    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    /// The digits the editor starts from, or nil when the stored value holds something else, which is then edited as plain text.
    public func digits(_ value: String) -> String? {
        switch self {
        case .number: return value.allSatisfy { Self.isDigit($0) || $0 == " " || $0 == "-" } ? value.filter(Self.isDigit) : nil
        case .expiry: return value.allSatisfy(Self.isDigit) ? value : Cards.parseExpiry(value).map(Cards.expiryDigits)
        }
    }
    /// What to store for `typed`: its digits, at most `maxDigits`. An expiry starting with 2–9 is a one-digit month, so 3 becomes 03.
    public func clean(_ typed: String) -> String {
        let digits = String(typed.filter(Self.isDigit).prefix(maxDigits))
        if self == .expiry, digits.count == 1, let first = digits.first, ("2"..."9").contains(first) { return "0" + digits }
        return digits
    }
    /// What to store when the shown text became `typed`. Deleting a separator deletes the digit before it, so backspace on "02/" leaves "0".
    public func edited(_ typed: String, from stored: String) -> String {
        let value = clean(typed)
        return value == stored && typed.count < formatted(stored).count ? String(stored.dropLast()) : value
    }
    /// The digit counts followed by a separator. One shows as soon as its group is typed ("5241" reads "5241 ", "02" reads "02/"), except
    /// after a complete 16-digit number.
    public func breaks(_ digits: String) -> [Int] {
        let all = self == .expiry ? [2] : Cards.brand(digits) == "American Express" ? [4, 10] : [4, 8, 12, 16]
        return all.filter { $0 < digits.count || ($0 == digits.count && $0 != 16) }
    }
    public func formatted(_ digits: String) -> String {
        let breaks = Set(breaks(digits)); var out = ""
        for (i, c) in digits.enumerated() { out.append(c); if breaks.contains(i + 1) { out.append(separator) } }
        return out
    }
}
