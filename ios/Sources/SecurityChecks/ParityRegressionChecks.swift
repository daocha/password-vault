import Foundation
import VaultCore

func parityRegressionChecks() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let records = try Records.decode(Data(contentsOf: root.appendingPathComponent("fixtures/list-parity/records.json")))
    let selected = Set(records.map(\.id))
    for filter in [VaultListFilter(folder: "Work"), VaultListFilter(favorites: true), VaultListFilter(kind: "card"), VaultListFilter(query: "alice"), VaultListFilter(tab: .totp)] {
        let visible = filter.apply(to: records)
        let ids = VaultListFilter.visibleSelection(selected, in: visible)
        try check(ids == Set(visible.map(\.id)), "bulk actions discard hidden selections for every filter")
        let updated = records.filter { !ids.contains($0.id) }
        try check(records.filter { !visible.contains($0) }.allSatisfy(updated.contains), "bulk deletion keeps every hidden entry")
    }
    var a = VaultRecord(), b = VaultRecord(), untouched = VaultRecord()
    a.group = "A"; b.group = "a "; untouched.group = "Other"
    let grouped = [a, b, untouched]
    var assignment = VaultGroupAssignment(records: grouped, ids: [a.id, b.id])
    try check(assignment.names == ["A", "Other"] && assignment.membership("A") == true, "group picker combines case variants as Android does")
    try check(!assignment.hasChanges && assignment.applying(to: grouped, now: "unused") == grouped, "opening/cancelling groups keeps records and timestamps")
    assignment.add(" other ")
    let applied = assignment.applying(to: grouped, now: "2026-11-02T12:00:00.123Z")
    try check(grouped[0].group == "A" && applied[0].group == "Other" && applied[1].group == "Other", "groups are staged and existing spelling is reused on Apply")
    try check(applied[2] == untouched && applied[0].fields == a.fields && applied[0].updatedAt == "2026-11-02T12:00:00.123Z", "group Apply changes only the selected records' group and timestamp")
    assignment.assign("")
    try check(assignment.applying(to: grouped, now: "now").prefix(2).allSatisfy { $0.group.isEmpty }, "selected entries can be ungrouped")

    let account = try TotpAccount(secret: Data([1, 2, 3]))
    try check(abs(account.remainingFraction(at: Date(timeIntervalSince1970: 29.75)) - 0.25 / 30) < 0.000001, "2FA ring includes fractional seconds")
    try check(account.remaining(at: Date(timeIntervalSince1970: 29.75)) == 1 && account.remainingFraction(at: Date(timeIntervalSince1970: 30)) == 1, "2FA countdown and ring reset at the same boundary")

    for (language, expected) in [("zh-Hans", ["共 10 个条目，显示 2 个", "共 10 条助记词，显示 2 条"]), ("zh-Hant", ["共 10 個項目，顯示 2 個", "共 10 組助記詞，顯示 2 組"])] {
        let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("ios/PassVault/\(language).lproj/Localizable.strings")), format: nil) as! [String: String]
        for (index, key) in ["%lld of %lld entries", "%lld of %lld seed phrases"].enumerated() {
            try check(String(format: table[key]!, Int64(2), Int64(10)) == expected[index], "\(language) formats visible/total counts in the correct order")
        }
    }

    let suite = "PassVault.parity-checks.\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let status = BackupStatus(defaults: defaults), decoyStatus = BackupStatus(defaults: defaults, decoy: true)
    let completed = Date(timeIntervalSince1970: 1_793_620_860)
    defaults.set(completed, forKey: "lastBackupAt")
    try check(status.snapshotAt == completed, "legacy backup history falls back to completion time")
    let password = "A lengthy test passphrase 1!", store = MemoryStorage(), engine = VaultEngine(storage: store)
    _ = try engine.create(password: password)
    try engine.save([a])
    try engine.enableBiometrics(password: password)
    try check(engine.biometricsEnabled(), "biometric presence does not release or require a key")
    try engine.disableBiometrics()
    engine.lock()
    try rejects("disabled biometrics cannot unlock") { _ = try engine.unlockBiometric() }
    try rejects("locked engine cannot change biometric settings") { try engine.disableBiometrics() }
    _ = try engine.unlock(password: password)
    try engine.enableBiometrics(password: password)
    let mainExport = try engine.prepareExport(password: password, csv: false, instance: { BackupStatus(defaults: defaults, decoy: $0).instance })
    var edited = a; edited.updatedAt = VaultTimestamp.format(mainExport.snapshotAt.addingTimeInterval(0.25))
    try engine.save([edited])
    let savedAt = mainExport.snapshotAt.addingTimeInterval(60)
    mainExport.recordBackup(defaults: defaults, savedAt: savedAt)
    try check(status.lastBackup == savedAt && status.snapshotAt == mainExport.snapshotAt, "export records both completion and original snapshot")
    try check(VaultCrypto.importBackup(mainExport.data, password: password) == [a], "saved bytes belong to the original snapshot")
    try check(BackupReminder.due([edited], lastBackup: status.lastBackup, intervalDays: 30, snoozedUntil: nil, now: savedAt.addingTimeInterval(31 * 86400), snapshotAt: status.snapshotAt), "edits during saving remain unbacked after the reminder interval")
    let csv = try engine.prepareExport(password: password, csv: true)
    csv.recordBackup(defaults: defaults, savedAt: savedAt.addingTimeInterval(60))
    try check(status.lastBackup == savedAt, "CSV never changes encrypted backup history")

    let decoyPassword = "A separate decoy passphrase 2!"
    try engine.createDecoy(password: password, decoyPassword: decoyPassword)
    engine.lock(); _ = try engine.unlock(password: decoyPassword)
    try check(!engine.biometricsEnabled(), "decoy does not expose main vault biometric settings")
    try rejects("decoy cannot disable main vault biometrics") { try engine.disableBiometrics() }
    let decoyExport = try engine.prepareExport(password: decoyPassword, csv: false, instance: { BackupStatus(defaults: defaults, decoy: $0).instance })
    engine.lock(); _ = try engine.unlockBiometric()
    decoyExport.recordBackup(defaults: defaults, savedAt: savedAt)
    try check(decoyStatus.lastBackup == savedAt && status.snapshotAt == mainExport.snapshotAt, "a late decoy export updates only its source vault")
    status.intervalDays = 7; status.snoozedUntil = savedAt
    status.clear(); decoyStatus.clear()
    mainExport.recordBackup(defaults: defaults); decoyExport.recordBackup(defaults: defaults)
    try check(status.lastBackup == nil && decoyStatus.lastBackup == nil && status.snapshotAt == nil, "reset rejects late callbacks from both erased vaults")
    try check(status.intervalDays == 30 && status.snoozedUntil == nil && BackupReminder.due([edited], lastBackup: status.lastBackup, intervalDays: status.intervalDays, snoozedUntil: status.snoozedUntil), "new vault starts with a first-backup reminder and default preferences")
}
