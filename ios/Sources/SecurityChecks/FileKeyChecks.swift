import Foundation
import VaultCore

/// Android's ordinary secure-note file keys must survive imports and edits on iOS too.
func fileKeyChecks() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
    let hybrid = try String(contentsOf: root.appendingPathComponent("fixtures/age-spec/hybrid-key.txt"), encoding: .utf8).components(separatedBy: .newlines)[0]
    let classic = "AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX"
    let password = "A lengthy test passphrase 1!", store = MemoryStorage(), engine = VaultEngine(storage: store)
    _ = try engine.create(password: password)
    func key(_ secret: String) -> VaultRecord {
        var r = VaultRecord(); r.type = "note"; r.name = "File key"
        r.fields = [.init(kind: .password, label: "age secret key", value: secret)]
        r.updatedAt = "2026-01-01T00:00:00Z"; return r
    }
    let keys = [key(classic), key(hybrid)]
    try engine.save(keys)
    var imported = VaultRecord(); imported.name = "Old backup login"
    let restored = try engine.replaceAll([imported])
    try check(restored.count == 3 && keys.allSatisfy { k in restored.contains { $0.fields == k.fields } }, "iOS replacement preserves both age key types")
    engine.lock()
    var loaded = try engine.unlock(password: password)
    try check(loaded.count == 3, "retained file keys persist across lock/unlock")
    try check(loaded.filter(\.isNote).allSatisfy { $0.legacy["fileKeyCreated"] == "2026-01-01T00:00:00Z" }, "iOS stamps old keys before editing")
    // Same id, another secret: keep both; the incoming record owns the original id.
    var collision = keys[0]; collision.fields[0].value = hybrid
    let merged = try engine.merge([collision])
    try check(merged.contains { $0.fields == keys[0].fields && $0.id != collision.id } && merged.contains { $0.id == collision.id && $0.fields == collision.fields }, "same-id import preserves displaced identity")
    // A login can reuse a key id too.
    imported.id = keys[1].id
    let reused = try engine.merge([imported])
    try check(reused.contains { $0.id == imported.id && !$0.isNote } && reused.contains { $0.isNote && $0.fields.first?.value == hybrid }, "same-id login cannot discard a file key")
    // Matching the same secret under a different id/case/whitespace does not create duplicates.
    var matching = key(" \n" + classic.lowercased() + "\n")
    let matchingImport = try engine.replaceAll([matching])
    try check(matchingImport.count == 2, "equivalent imported secret is not retained twice")
    engine.lock(); loaded = try engine.unlock(password: password)
    matching = loaded.first { $0.id == matching.id }!
    matching.updatedAt = "2030-01-01T00:00:00Z"
    try engine.save([matching]) // An explicit save/delete remains allowed.
    engine.lock(); loaded = try engine.unlock(password: password)
    try check(loaded[0].legacy["fileKeyCreated"] == "2026-01-01T00:00:00Z", "editing does not rotate an old unstamped key")
    // Corrupted Bech32, mixed case and wrong record types are ordinary notes, not undeletable file keys.
    for secret in [String(classic.dropLast()) + "Y", "AGE-secret-KEY-" + String(classic.dropFirst(15)), "AGE-SECRET-KEY-PQ-1invalid"] {
        try engine.save([key(secret)])
        try check(try engine.replaceAll([]).isEmpty, "invalid age key is not preserved")
    }
    var wrongType = key(classic); wrongType.type = nil
    try engine.save([wrongType]); try check(try engine.replaceAll([]).isEmpty, "only note fields identify file keys")
}
