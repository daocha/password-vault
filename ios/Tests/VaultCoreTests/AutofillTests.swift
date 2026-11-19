import XCTest
@testable import VaultCore

/// AutoFill's website matching. The same cases as Android's `AutofillDomainsTest`, plus the picker's order.
final class AutofillTests: XCTestCase {
    private func base(_ host: String) -> String? { AutofillDomains.host(host).flatMap(AutofillDomains.registrable) }

    func testTheBundledListLoadsAndMatchesAndroidsCopy() throws {
        XCTAssertTrue(AutofillDomains.listLoaded)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ios = try Data(contentsOf: root.appendingPathComponent("ios/Sources/VaultCore/Resources/public_suffix_list.dat"))
        let android = try Data(contentsOf: root.appendingPathComponent("android/app/src/main/resources/public_suffix_list.dat"))
        XCTAssertEqual(ios, android, "both apps use the same list")
    }

    func testPrivateHostingTenantsAreDifferentSites() {
        for suffix in ["github.io", "pages.dev", "gitlab.io", "appspot.com", "blogspot.com", "s3.amazonaws.com"] {
            XCTAssertEqual(base("victim.\(suffix)"), "victim.\(suffix)")
            XCTAssertFalse(AutofillDomains.sameSite("https://victim.\(suffix)", "attacker.\(suffix)"), suffix)
            XCTAssertTrue(AutofillDomains.sameSite("https://login.victim.\(suffix)", "victim.\(suffix)"), suffix)
        }
    }

    func testFollowsPublicSuffixWildcardAndExceptionRules() {
        XCTAssertEqual(base("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertNil(base("co.uk"))
        XCTAssertNil(base("github.io"))
        XCTAssertNil(base("foo.ck")) // *.ck
        XCTAssertEqual(base("bar.foo.ck"), "bar.foo.ck")
        XCTAssertEqual(base("login.www.ck"), "www.ck") // !www.ck
        XCTAssertNil(base("ward.kawasaki.jp")) // *.kawasaki.jp
        XCTAssertEqual(base("www.city.kawasaki.jp"), "city.kawasaki.jp")
        XCTAssertEqual(base("login.example.unknown-tld"), "example.unknown-tld") // implicit *
        XCTAssertNotNil(base("example.ᬩᬮᬶ.id"))
        XCTAssertNil(base("公司.cn"), "a Unicode public suffix on its own")
        XCTAssertFalse(AutofillDomains.sameSite("https://a.公司.cn", "b.公司.cn"))
    }

    func testIPAddressesAreComparedAsCompleteLiterals() {
        XCTAssertFalse(AutofillDomains.sameSite("https://10.0.0.1", "192.168.0.1"))
        XCTAssertTrue(AutofillDomains.sameSite("https://10.0.0.1:443/login", "10.0.0.1"))
        XCTAssertFalse(AutofillDomains.sameSite("https://[2001:db8::1]/", "2001:db8::2"))
        XCTAssertTrue(AutofillDomains.sameSite("https://[2001:db8::1]/", "2001:db8::1"))
        for ambiguous in ["127.1", "0177.0.0.1", "2130706433", "0x7f000001", "0x7f.0.0.1", "1.2.3.0x4", "[::g]", "[1.2.3.4]"] {
            XCTAssertNil(AutofillDomains.host(ambiguous), ambiguous)
        }
    }

    func testCanonicalizesInternationalNamesWithoutCollapsingDistinctSites() {
        XCTAssertTrue(AutofillDomains.sameSite("https://bücher.de/login", "xn--bcher-kva.de"))
        XCTAssertTrue(AutofillDomains.sameSite("https://www.Example.COM./", "example.com"))
        XCTAssertFalse(AutofillDomains.sameSite("https://faß.de", "fass.de"))
        XCTAssertFalse(AutofillDomains.sameSite("https://xn--fa-hia.de", "fass.de"))
        XCTAssertFalse(AutofillDomains.sameSite("https://apple.com", "аpple.com")) // Cyrillic 'а'
        XCTAssertTrue(AutofillDomains.sameSite("https://例え。テスト", "xn--r8jz45g.xn--zckzah"), "an ideographic full stop separates labels")
    }

    func testRefusesAmbiguousOrMalformedOrigins() {
        for bad in ["https://bank.com@evil.com", "https://evil.com\\@bank.com", "javascript://bank.com", "https://bank.com:bad", "https://bank.com:99999",
                    "https://bank.com:", "https://bank..com", "https://bank.com..", "https://bank.com%2eevil.com", "https://bank.com\nevil.com",
                    "https://bank_com.com", "https://-bank.com", "ftp://bank.com", "https://", "", "https://bank.com:0"] {
            XCTAssertNil(AutofillDomains.host(bad), bad)
        }
        XCTAssertEqual(AutofillDomains.host("HTTPS://Login.Bank.com:8443/path?q#f"), "login.bank.com")
        XCTAssertEqual(AutofillDomains.host("bank.com/login"), "bank.com")
    }

    func testLoginsForTheSiteComeFirstFavoritesLeading() {
        func login(_ name: String, _ website: String, favorite: Bool = false, username: String = "me", type: String? = nil) -> VaultRecord {
            var record = VaultRecord(); record.name = name; record.website = website; record.favorite = favorite; record.type = type
            record.fields[0].value = username; record.fields[1].value = "secret"
            return record
        }
        var empty = login("Empty", "https://bank.com"); empty.fields[0].value = ""; empty.fields[1].value = ""
        let records = [login("Zeta Bank", "https://www.bank.com"), login("Alpha Bank", "bank.com/login", favorite: true), login("Mail", "https://mail.example"),
                       login("Bank card", "https://bank.com", type: "card"), login("Tenant", "https://bank.github.io"), empty,
                       login("Other tenant", "https://other.github.io")]
        let logins = AutofillMatch.candidates(records)
        XCTAssertEqual(logins.map(\.name), ["Zeta Bank", "Alpha Bank", "Mail", "Tenant", "Other tenant"], "only logins with something to fill")
        let sites = AutofillMatch.sites(["https://login.bank.com/signin", "bank.com", "not a host"])
        XCTAssertEqual(sites, ["login.bank.com", "bank.com"])
        let shown = AutofillMatch.shown(logins, sites: sites, query: "")
        XCTAssertTrue(shown.suggested)
        XCTAssertEqual(shown.records.map(\.name), ["Alpha Bank", "Zeta Bank"])
        let unknown = AutofillMatch.shown(logins, sites: ["https://unknown.example"], query: "")
        XCTAssertFalse(unknown.suggested)
        XCTAssertEqual(unknown.records.map(\.name), ["Alpha Bank", "Mail", "Other tenant", "Tenant", "Zeta Bank"], "no match: every login, by name")
        let tenant = AutofillMatch.shown(logins, sites: AutofillMatch.sites(["https://bank.github.io"]), query: "")
        XCTAssertEqual(tenant.records.map(\.name), ["Tenant"], "another tenant of the same host is a different site")
        let search = AutofillMatch.shown(logins, sites: sites, query: "  bank ")
        XCTAssertEqual(search.records.map(\.name), ["Alpha Bank", "Zeta Bank", "Tenant"], "a search finds every login, suggested ones first")
        XCTAssertEqual(AutofillMatch.shown(logins, sites: sites, query: "mail").records.map(\.name), ["Mail"])
        XCTAssertEqual(AutofillMatch.username(logins[0]), "me")
        XCTAssertEqual(AutofillMatch.password(logins[0]), "secret")
    }
}

/// The AutoFill extension's set-up and the rules it keeps, read from its sources (they build only with Xcode).
final class AutofillExtensionTests: XCTestCase {
    private let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func text(_ path: String) throws -> String { try String(contentsOf: ios.appendingPathComponent(path), encoding: .utf8) }
    private func table(_ path: String) throws -> [String: String] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: ios.appendingPathComponent(path)), format: nil) as? [String: String])
    }
    private func placeholders(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(\\d\\$)?(lld|@|d)")
        return pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range(at: 2)) }.sorted()
    }

    func testEveryTextIsTranslatedWithTheSamePlaceholders() throws {
        let english = try table("AutoFill/en.lproj/Localizable.strings")
        for language in ["zh-Hans", "zh-Hant"] {
            let translated = try table("AutoFill/\(language).lproj/Localizable.strings")
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in translated { XCTAssertEqual(placeholders(value), placeholders(key), "\(language): \(key)") }
        }
        // Every literal the extension shows is in the table (Text, Button, alerts, titles and localized()).
        let sources = try ["AutoFill/AutofillViews.swift", "AutoFill/AutofillModel.swift"].map(text).joined()
        let literal = try NSRegularExpression(pattern: "(?:Text|Button|localized|localizedFormat|navigationTitle|alert|Label|accessibilityLabel)\\(\"((?:[^\"\\\\]|\\\\.)+)\"")
        let used = literal.matches(in: sources, range: NSRange(sources.startIndex..., in: sources)).map { (sources as NSString).substring(with: $0.range(at: 1)).replacingOccurrences(of: "\\n", with: "\n") }
        XCTAssertGreaterThan(used.count, 10)
        for key in used { XCTAssertNotNil(english[key], "missing from AutoFill/en.lproj: \(key)") }
        for key in ["No logins with a username or password yet.", "No logins match your search.", "Search", "Suggested", "All logins", "Show password", "Hide password",
                    "Unlock your password vault", "Open PassVault once, then try AutoFill again.", VaultError.erased.localizedDescription] {
            XCTAssertNotNil(english[key], key)
        }
        // The app's own strings for its AutoFill panel.
        let autofillPanel = ["AutoFill", "On", "Off", "Open AutoFill settings", "Show logins above the keyboard",
                             "Needed for iOS to offer PassVault in login forms. iOS then keeps each login's website and username outside the encrypted vault. Passwords stay in the vault.", "AutoFill cannot open your vault yet. Close PassVault and open it again.",
                             "PassVault asks for your app password or Face ID / Touch ID before every fill.", "Unlock your password vault"]
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let app = try table("PassVault/\(language).lproj/Localizable.strings")
            for key in autofillPanel { XCTAssertNotNil(app[key], "\(language): \(key)") }
        }
        // The panel is the Settings button and one line, not a walkthrough of iOS Settings.
        let appSource = try String(contentsOf: ios.appendingPathComponent("PassVault/PassVaultApp.swift"), encoding: .utf8)
        XCTAssertFalse(appSource.contains("1. Open Settings"))
    }

    func testIOSIsGivenOnlyTheSiteAndUsernameOfFillableLogins() {
        var bank = VaultRecord(); bank.website = "https://login.bank.co.uk/x"; bank.fields[0].value = "me"; bank.fields[1].value = "secret"
        var noUser = VaultRecord(); noUser.name = "Agoda"; noUser.website = "agoda.com"; noUser.fields[1].value = "pw"
        var noSite = VaultRecord(); noSite.name = "Booking"; noSite.fields[0].value = "me"; noSite.fields[1].value = "pw"
        var card = VaultRecord(); card.type = "card"; card.website = "bank.com"; card.fields[0].value = "me"; card.fields[1].value = "1234"
        XCTAssertEqual(AutofillIdentities.entries([bank, noUser, noSite, card]), [AutofillIdentities.Entry(domain: "bank.co.uk", user: "me", recordID: bank.id),
                                                                                  AutofillIdentities.Entry(domain: "agoda.com", user: "Agoda", recordID: noUser.id)])
        XCTAssertEqual(AutofillIdentities.skipped([bank, noUser, noSite, card]), [.init(reason: .noWebsite, names: ["Booking"])])
    }

    func testTheExtensionIsAPasswordProviderSharingOnlyTheAppGroup() throws {
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: ios.appendingPathComponent("AutoFill/Info.plist")), format: nil) as? [String: Any])
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.authentication-services-credential-provider-ui")
        XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String, "$(PRODUCT_MODULE_NAME).CredentialProviderViewController")
        let capabilities = try XCTUnwrap((ext["NSExtensionAttributes"] as? [String: Any])?["ASCredentialProviderExtensionCapabilities"] as? [String: Bool])
        XCTAssertEqual(capabilities, ["ProvidesPasswords": true], "passwords only: no passkeys, one-time codes or saving")
        for path in ["AutoFill/AutoFill.entitlements", "PassVault/PassVault.entitlements"] {
            let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: ios.appendingPathComponent(path)), format: nil) as? [String: Any])
            XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String], ["group.$(PASSVAULT_APP_ID)"], path)
            XCTAssertEqual(entitlements["com.apple.developer.authentication-services.autofill-credential-provider"] as? Bool, true, path)
            XCTAssertEqual(entitlements["com.apple.developer.default-data-protection"] as? String, "NSFileProtectionComplete", path)
            XCTAssertNil(entitlements["keychain-access-groups"], "the app group is the only shared Keychain group: \(path)")
        }
        let project = try text("project.yml")
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: $(PASSVAULT_APP_ID).autofill"))
        XCTAssertTrue(project.contains("      - target: PassVaultAutoFill"), "the app embeds the extension")
        XCTAssertTrue(project.contains("PASSVAULT_APP_ID: app.passvault.mobile.debug") && project.contains("PASSVAULT_APP_ID: app.passvault.mobile\n"))
        // iOS refuses to install an app whose extension has no CFBundleVersion. The version is set once for every target, so the
        // extension always matches the app, and no target sets its own.
        let header = try XCTUnwrap(project.components(separatedBy: "\ntargets:").first)
        XCTAssertTrue(header.contains("    MARKETING_VERSION: '") && header.contains("    CURRENT_PROJECT_VERSION: '"), "project-wide version")
        XCTAssertEqual(project.components(separatedBy: "MARKETING_VERSION:").count, 2, "no target overrides the version")
        XCTAssertEqual(project.components(separatedBy: "CURRENT_PROJECT_VERSION:").count, 2, "no target overrides the build number")
        XCTAssertNil(info["CFBundleVersion"]); XCTAssertNil(info["CFBundleShortVersionString"])
    }

    /// No usernames or websites go to the QuickType bar (the system's credential store is outside the encrypted vault), nothing goes
    /// online, the extension unlocks with half the memory, and it locks the vault when it fills or closes.
    func testTheExtensionKeepsTheVaultsRules() throws {
        let sources = try ["AutoFill/CredentialProviderViewController.swift", "AutoFill/AutofillModel.swift", "AutoFill/AutofillViews.swift"].map(text).joined()
        let app = try ["PassVault/PassVaultApp.swift", "PassVault/KeychainStorage.swift"].map(text).joined()
        for forbidden in ["saveCredentialIdentities", "replaceCredentialIdentities", "URLSession", "NWConnection", "UIPasteboard"] {
            XCTAssertFalse(sources.contains(forbidden), forbidden); XCTAssertFalse(app.contains(forbidden) && forbidden != "UIPasteboard", forbidden)
        }
        XCTAssertTrue(sources.contains("KeychainStorage(role: .autofill"))
        XCTAssertTrue(sources.contains("sequentialKeys: true"))
        XCTAssertTrue(sources.contains("ASExtensionError.Code.userInteractionRequired"), "nothing is filled without the user")
        XCTAssertTrue(sources.contains("protectedDataWillBecomeUnavailableNotification"), "locking the device ends the request")
        XCTAssertTrue(sources.contains(".alert(\"Fill this login?\""), "every fill is confirmed")
        let fill = try XCTUnwrap(sources.range(of: "func fill(")).upperBound
        XCTAssertTrue(sources[fill...].prefix(400).contains("close()"), "filling locks the vault")
        XCTAssertTrue(app.contains("keepAlive: BackgroundHold.hold"), "the app stays awake while it holds the shared lock")
    }
}
