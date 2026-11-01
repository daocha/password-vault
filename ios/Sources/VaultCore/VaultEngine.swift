import Foundation

// The adapter must persist state atomically in protected storage, never ordinary preferences.
public protocol VaultStorage: AnyObject {
    func readState() throws -> Data?
    func writeState(_ data: Data) throws
    func deleteState() throws
    func readBlob(_ id: String) throws -> Data
    func writeBlob(_ data: Data, id: String) throws
    /// Deletes every vault file except those named in `ids`.
    func removeBlobs(keeping ids: Set<String>) throws
    func hasBlobs() throws -> Bool
    func saveBiometricKey(_ data: Data) throws
    func readBiometricKey() throws -> Data
    func deleteBiometricKey() throws
}
/// The second, decoy vault: its own wrapped data key and file, opened by its own password (see `VaultEngine.createDecoy`).
///
/// The last three keys are the real vault's way back into the decoy, so it can give the decoy a new password without losing its contents:
/// `owner` is an X25519 public key whose secret key is sealed under the real vault's data key (`ownerSecret`), and `recovery` is the decoy's
/// data key in a sealed box to `owner`. The decoy vault can write a new `recovery` when its password changes but cannot read one.
/// Decoys set up by earlier test builds have none of them.
struct DecoySlot: Codable {
    var salt: Data
    var secret: Data
    var wrappedKey: Data
    var blob: String
    var owner: Data? = nil
    var ownerSecret: Data? = nil
    var recovery: Data? = nil
}
struct DeviceState: Codable {
    var version = 1
    var attempts = 0
    var erased = false
    var salt: Data
    var secret: Data
    var wrappedKey: Data
    var blob: String
    /// Absent (and omitted from the state) unless a decoy vault was set up.
    var decoy: DecoySlot? = nil
    /// Decoy password changes since the real password or biometrics last opened the vault (see `VaultEngine.changePassword`); omitted when 0.
    var decoyChanges: Int? = nil
}
public final class VaultEngine: @unchecked Sendable {
    private let storage: VaultStorage
    private let mutex = NSRecursiveLock()
    private var key: Data?
    private var records = [VaultRecord]()
    /// Whether the open vault is the decoy one. Every operation acts on the open vault only.
    private var activeDecoy = false
    private static let keyAAD = Data("PassVault/key/v1".utf8)
    private static let ownerAAD = Data("PassVault/decoy-owner/v1".utf8)
    /// Decoy password changes allowed between openings by the real password or biometrics.
    public static let decoyChanges = 3
    public init(storage: VaultStorage) { self.storage = storage }
    private func serialized<T>(_ action: () throws -> T) rethrows -> T { mutex.lock(); defer { mutex.unlock() }; return try action() }
    /// State saved by a newer PassVault may not decode as this version's layout, so its version is read first.
    private static func decodeState(_ data: Data) throws -> DeviceState {
        struct Stamp: Decodable { var version: Int }
        if let stamp = try? JSONDecoder().decode(Stamp.self, from: data), stamp.version > 1 { throw VaultError.newerVault }
        return try JSONDecoder().decode(DeviceState.self, from: data)
    }
    private func state() throws -> DeviceState? {
        guard let data = try storage.readState() else {
            guard try !storage.hasBlobs() else { throw VaultError.invalid("Protected state is missing. Vault access is refused.") }
            return nil
        }
        let value = try Self.decodeState(data)
        guard value.version == 1, (0...10).contains(value.attempts), UUID(uuidString: value.blob) != nil else { throw VaultError.invalid("Damaged protected state.") }
        if value.erased { throw VaultError.erased }
        if value.attempts >= 10 { try erase(value); throw VaultError.erased }
        guard value.salt.count == 16, value.secret.count == 32, value.wrappedKey.count == 72 else { throw VaultError.invalid("Damaged protected keys.") }
        if let d = value.decoy {
            guard d.salt.count == 16, d.secret.count == 32, d.wrappedKey.count == 72, UUID(uuidString: d.blob) != nil else { throw VaultError.invalid("Damaged protected keys.") }
            let parts = [d.owner?.count, d.ownerSecret?.count, d.recovery?.count]
            guard parts == [nil, nil, nil] || parts == [32, 72, 80] else { throw VaultError.invalid("Damaged protected keys.") }
        }
        guard (0...Self.decoyChanges).contains(value.decoyChanges ?? 0) else { throw VaultError.invalid("Damaged protected state.") }
        return value
    }
    private func write(_ value: DeviceState) throws { try storage.writeState(JSONEncoder().encode(value)) }
    /// The vault files the state points at: the main one and, if set up, the decoy one.
    private func liveBlobs(_ value: DeviceState) -> Set<String> { Set([value.blob] + [value.decoy?.blob].compactMap { $0 }) }
    public func exists() throws -> Bool { try serialized { try state() != nil } }
    /// True after erasure, and also when ciphertext exists without its protected state (e.g. the device passcode was removed,
    /// which deletes the Keychain items): nothing can decrypt it, so it may be reset like an erased vault.
    public func isErased() throws -> Bool { try serialized {
        guard let data = try storage.readState() else { return try storage.hasBlobs() }
        return try Self.decodeState(data).erased
    } }
    public func resetErasedVault() throws { try serialized {
        guard try isErased() else { throw VaultError.invalid("Only an already-erased vault can be reset without a password.") }
        lock(); try storage.deleteBiometricKey(); try storage.removeBlobs(keeping: []); try storage.deleteState()
    } }
    public func remainingAttempts() throws -> Int { try serialized { 10 - (try state()?.attempts ?? 0) } }
    public func lock() { serialized { let count = key?.count ?? 0; key?.resetBytes(in: 0..<count); key = nil; records = []; activeDecoy = false } }
    /// Wraps `dataKey` under `password` with a fresh salt and device secret.
    private func wrap(_ password: String, dataKey: Data) throws -> (salt: Data, secret: Data, wrapped: Data) {
        let salt = VaultCrypto.random(16), secret = VaultCrypto.random(32)
        var derived = try VaultCrypto.passwordKey(password, salt: salt)
        defer { derived.resetBytes(in: 0..<derived.count) }
        var wrapping = try VaultCrypto.deviceKey(derived, secret: secret)
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        return (salt, secret, try VaultCrypto.seal(dataKey, key: wrapping, aad: Self.keyAAD))
    }
    /// The data key `password` unwraps, or nil. `legacy` keys from the text exactly as typed (vaults made before normalization).
    private func unwrap(_ password: String, salt: Data, secret: Data, wrapped: Data, legacy: Bool = false) throws -> Data? {
        var derived = try VaultCrypto.passwordKey(password, salt: salt, legacyEncoding: legacy)
        defer { derived.resetBytes(in: 0..<derived.count) }
        var wrapping = try VaultCrypto.deviceKey(derived, secret: secret)
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        do { return try VaultCrypto.open(wrapped, key: wrapping, aad: Self.keyAAD) } catch VaultError.authentication { return nil }
    }
    public func create(password: String) throws -> [VaultRecord] { try serialized {
        guard try state() == nil else { throw VaultError.invalid("A vault already exists.") }
        try VaultCrypto.requireStrongPassword(password)
        let dataKey = VaultCrypto.random(32), wrapped = try wrap(password, dataKey: dataKey)
        let blob = UUID().uuidString
        let value = DeviceState(salt: wrapped.salt, secret: wrapped.secret, wrappedKey: wrapped.wrapped, blob: blob)
        try storage.writeBlob(VaultCrypto.seal(Records.encode([]), key: dataKey, aad: Data(blob.utf8)), id: blob)
        // Without its state the new file would block every later attempt ("Protected state is missing"), e.g. when no passcode is set.
        do { try write(value) } catch { try? storage.removeBlobs(keeping: []); throw error }
        key = dataKey; records = []; activeDecoy = false; return []
    } }
    /**
     * Checks `password` as one counted attempt and returns the data key it opens and whether that is the decoy vault's.
     * Unlocking (`unlocking`) accepts either vault's password and always derives two keys (the decoy's, or a throwaway one when there is
     * no decoy), so its timing does not reveal whether a decoy exists. Other checks accept only the open vault's password. The main
     * password clears the failure count and the decoy's password-change allowance; the decoy password leaves both as they were, so decoy
     * sign-ins cannot reset guesses at the main one.
     */
    private func authenticate(_ password: String, unlocking: Bool = false) throws -> (key: Data, decoy: Bool) {
        guard var value = try state() else { throw VaultError.locked }
        let before = value.attempts
        value.attempts += 1
        try write(value) // Reserve before expensive work; interruption consumes this attempt.
        let checkMain = unlocking || !activeDecoy, checkDecoy = unlocking || activeDecoy
        var main: Data?, legacy = false
        if checkMain {
            // Vaults made before passwords were normalized are keyed from the text exactly as typed. Accept that form once and re-wrap in the
            // normalized form below. Both forms count as one attempt.
            for raw in PasswordText.differs(password) ? [false, true] : [false] {
                if let found = try unwrap(password, salt: value.salt, secret: value.secret, wrapped: value.wrappedKey, legacy: raw) { main = found; legacy = raw; break }
            }
        }
        var decoy: Data?
        if checkDecoy {
            if let d = value.decoy { decoy = try unwrap(password, salt: d.salt, secret: d.secret, wrapped: d.wrappedKey) }
            else if unlocking { var throwaway = try VaultCrypto.passwordKey(password, salt: VaultCrypto.random(16)); throwaway.resetBytes(in: 0..<throwaway.count) }
        }
        if let main {
            value.attempts = 0; value.decoyChanges = nil
            if legacy { let wrapped = try wrap(password, dataKey: main); value.salt = wrapped.salt; value.secret = wrapped.secret; value.wrappedKey = wrapped.wrapped }
            try write(value)
            return (main, false)
        }
        if let decoy { value.attempts = before; try write(value); return (decoy, true) }
        lock()
        if value.attempts == 10 { try erase(value); throw VaultError.erased }
        throw VaultError.authentication
    }
    private func load(_ candidate: Data, decoy: Bool) throws -> [VaultRecord] {
        guard let value = try state() else { throw VaultError.locked }
        guard let blob = decoy ? value.decoy?.blob : value.blob else { throw VaultError.locked }
        var plaintext = try VaultCrypto.open(storage.readBlob(blob), key: candidate, aad: Data(blob.utf8))
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let loaded = FileKeys.stamp(try Records.decode(plaintext))
        key = candidate; records = loaded; activeDecoy = decoy; return loaded
    }
    public func unlock(password: String) throws -> [VaultRecord] { try serialized { let found = try authenticate(password, unlocking: true); return try load(found.key, decoy: found.decoy) } }
    /// Biometrics always open the main vault. The key is released only by the Secure Enclave after a biometric match, which proves the owner is
    /// present, so like the main password it clears failed password attempts and the decoy's password-change allowance.
    public func unlockBiometric() throws -> [VaultRecord] { try serialized {
        guard var value = try state() else { throw VaultError.locked }
        let loaded = try load(storage.readBiometricKey(), decoy: false)
        if value.attempts != 0 || value.decoyChanges != nil { value.attempts = 0; value.decoyChanges = nil; try write(value) }
        return loaded
    } }
    public func enableBiometrics(password: String) throws { try serialized {
        guard !activeDecoy else { throw VaultError.locked }
        var candidate = try authenticate(password).key; defer { candidate.resetBytes(in: 0..<candidate.count) }
        try storage.saveBiometricKey(candidate)
    } }
    /// Whether the open vault is the decoy one.
    public func isDecoy() -> Bool { serialized { activeDecoy } }
    /// Whether a decoy vault exists. Only the main vault can tell; from the decoy vault this is always false.
    public func hasDecoy() throws -> Bool { try serialized { guard !activeDecoy, key != nil else { return false }; return try state()?.decoy != nil } }
    /// Whether the real vault can give the decoy a new password (`resetDecoyPassword`); decoys set up by earlier test builds cannot.
    public func canResetDecoy() throws -> Bool { try serialized { guard !activeDecoy, key != nil else { return false }; return try state()?.decoy?.recovery != nil } }
    public func save(_ updated: [VaultRecord]) throws { try serialized {
        guard let key, var value = try state() else { throw VaultError.locked }
        let updated = FileKeys.stamp(updated)
        let blob = UUID().uuidString
        try storage.writeBlob(VaultCrypto.seal(Records.encode(updated), key: key, aad: Data(blob.utf8)), id: blob)
        if activeDecoy { guard value.decoy != nil else { throw VaultError.locked }; value.decoy!.blob = blob } else { value.blob = blob }
        try write(value) // Commit pointer only after durable ciphertext.
        records = updated
        try storage.removeBlobs(keeping: liveBlobs(value))
    } }
    /// Changes the open vault's password: the decoy vault's when the decoy is open. Also replaces the data key and re-encrypts the vault, so
    /// nothing derived from the old password or old state can open future data.
    ///
    /// In the decoy vault the new password must not be the real one, and that check tests a guess at the real password: a refusal is counted
    /// as a failed attempt, and since an accepted change also tells that the guess was wrong, only `decoyChanges` changes are allowed until the
    /// real password or biometrics opens the vault. Past that the change is refused, never erased.
    public func changePassword(current: String, new: String) throws { try serialized {
        guard key != nil else { throw VaultError.locked }
        try VaultCrypto.requireStrongPassword(new)
        var proven = try authenticate(current).key; proven.resetBytes(in: 0..<proven.count) // the vault is unlocked, so the old data key is not needed again
        guard var value = try state() else { throw VaultError.locked }
        if activeDecoy {
            let changes = value.decoyChanges ?? 0
            guard changes < Self.decoyChanges else { throw VaultError.invalid("The password was changed too many times. Try again later.") }
            // Reserved before the check, as an attempt is: stopping the app mid-change must not give a free test.
            value.decoyChanges = changes + 1; try write(value)
            if var real = try unwrap(new, salt: value.salt, secret: value.secret, wrapped: value.wrappedKey) {
                real.resetBytes(in: 0..<real.count)
                value.decoyChanges = changes == 0 ? nil : changes; value.attempts += 1; try write(value)
                if value.attempts >= 10 { try erase(value); throw VaultError.erased }
                throw VaultError.invalid("Choose a different password.")
            }
        }
        if !activeDecoy, let d = value.decoy, try unwrap(new, salt: d.salt, secret: d.secret, wrapped: d.wrappedKey) != nil {
            throw VaultError.invalid("Choose a password different from your decoy vault's.")
        }
        let previous = liveBlobs(value), blob = UUID().uuidString, dataKey = VaultCrypto.random(32)
        var plaintext = try Records.encode(records); defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        try storage.writeBlob(VaultCrypto.seal(plaintext, key: dataKey, aad: Data(blob.utf8)), id: blob)
        do {
            let wrapped = try wrap(new, dataKey: dataKey)
            if activeDecoy {
                guard let old = value.decoy else { throw VaultError.locked }
                let recovery = try old.owner.map { try VaultCrypto.seal(dataKey, to: $0) }
                value.decoy = DecoySlot(salt: wrapped.salt, secret: wrapped.secret, wrappedKey: wrapped.wrapped, blob: blob, owner: old.owner, ownerSecret: old.ownerSecret, recovery: recovery)
            } else {
                // The way back into the decoy is sealed under the data key, so it moves to the new one.
                if let sealed = value.decoy?.ownerSecret, let key {
                    var owner = try VaultCrypto.open(sealed, key: key, aad: Self.ownerAAD); defer { owner.resetBytes(in: 0..<owner.count) }
                    value.decoy?.ownerSecret = try VaultCrypto.seal(owner, key: dataKey, aad: Self.ownerAAD)
                }
                // The biometric copy holds the old data key. Remove it before the commit so it cannot outlive the state that made it valid.
                try storage.deleteBiometricKey()
                value.salt = wrapped.salt; value.secret = wrapped.secret; value.wrappedKey = wrapped.wrapped; value.blob = blob
            }
            try write(value)
        } catch { try? storage.removeBlobs(keeping: previous); throw error }
        let count = key?.count ?? 0; key?.resetBytes(in: 0..<count); key = dataKey
        try storage.removeBlobs(keeping: liveBlobs(value))
    } }
    /// Sets up an empty decoy vault, opened from the unlock screen by `decoyPassword`. Only from the main vault, with its password.
    public func createDecoy(password: String, decoyPassword: String) throws { try serialized {
        guard key != nil, !activeDecoy else { throw VaultError.locked }
        try VaultCrypto.requireStrongPassword(decoyPassword)
        var proven = try authenticate(password).key; proven.resetBytes(in: 0..<proven.count)
        guard var value = try state() else { throw VaultError.locked }
        guard value.decoy == nil else { throw VaultError.invalid("A decoy vault already exists.") }
        if try unwrap(decoyPassword, salt: value.salt, secret: value.secret, wrapped: value.wrappedKey) != nil { throw VaultError.invalid("Choose a decoy password different from your app password.") }
        var dataKey = VaultCrypto.random(32); defer { dataKey.resetBytes(in: 0..<dataKey.count) }
        var pair = try VaultCrypto.boxKeyPair(); defer { pair.secret.resetBytes(in: 0..<pair.secret.count) }
        guard let key else { throw VaultError.locked }
        let wrapped = try wrap(decoyPassword, dataKey: dataKey), blob = UUID().uuidString
        try storage.writeBlob(VaultCrypto.seal(Records.encode([]), key: dataKey, aad: Data(blob.utf8)), id: blob)
        value.decoy = DecoySlot(salt: wrapped.salt, secret: wrapped.secret, wrappedKey: wrapped.wrapped, blob: blob, owner: pair.public,
                                ownerSecret: try VaultCrypto.seal(pair.secret, key: key, aad: Self.ownerAAD), recovery: try VaultCrypto.seal(dataKey, to: pair.public))
        value.decoyChanges = nil
        do { try write(value) } catch { try? storage.removeBlobs(keeping: [value.blob]); throw error }
    } }
    /// Gives the decoy vault a new password, keeping what is in it, for when its password is forgotten. Only from the main vault, with its
    /// password. The decoy is re-encrypted under a new data key, as a password change from inside it would be.
    public func resetDecoyPassword(password: String, decoyPassword: String) throws { try serialized {
        guard key != nil, !activeDecoy else { throw VaultError.locked }
        try VaultCrypto.requireStrongPassword(decoyPassword)
        var proven = try authenticate(password).key; proven.resetBytes(in: 0..<proven.count)
        guard var value = try state(), let key else { throw VaultError.locked }
        guard let decoy = value.decoy else { throw VaultError.invalid("There is no decoy vault.") }
        guard let owner = decoy.owner, let ownerSecret = decoy.ownerSecret, let recovery = decoy.recovery else {
            throw VaultError.invalid("This decoy vault was set up by an earlier test version. Remove it and set it up again.")
        }
        if try unwrap(decoyPassword, salt: value.salt, secret: value.secret, wrapped: value.wrappedKey) != nil { throw VaultError.invalid("Choose a decoy password different from your app password.") }
        var secretKey = try VaultCrypto.open(ownerSecret, key: key, aad: Self.ownerAAD); defer { secretKey.resetBytes(in: 0..<secretKey.count) }
        var oldKey = try VaultCrypto.openSealed(recovery, publicKey: owner, secretKey: secretKey); defer { oldKey.resetBytes(in: 0..<oldKey.count) }
        var plaintext = try VaultCrypto.open(storage.readBlob(decoy.blob), key: oldKey, aad: Data(decoy.blob.utf8)); defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let previous = liveBlobs(value), blob = UUID().uuidString
        var dataKey = VaultCrypto.random(32); defer { dataKey.resetBytes(in: 0..<dataKey.count) }
        try storage.writeBlob(VaultCrypto.seal(plaintext, key: dataKey, aad: Data(blob.utf8)), id: blob)
        do {
            let wrapped = try wrap(decoyPassword, dataKey: dataKey)
            value.decoy = DecoySlot(salt: wrapped.salt, secret: wrapped.secret, wrappedKey: wrapped.wrapped, blob: blob, owner: owner, ownerSecret: ownerSecret,
                                    recovery: try VaultCrypto.seal(dataKey, to: owner))
            value.decoyChanges = nil
            try write(value)
        } catch { try? storage.removeBlobs(keeping: previous); throw error }
        try storage.removeBlobs(keeping: liveBlobs(value))
    } }
    /// Deletes the decoy vault and everything in it. Only from the main vault, with its password.
    public func removeDecoy(password: String) throws { try serialized {
        guard key != nil, !activeDecoy else { throw VaultError.locked }
        var proven = try authenticate(password).key; proven.resetBytes(in: 0..<proven.count)
        guard var value = try state() else { throw VaultError.locked }
        value.decoy = nil; value.decoyChanges = nil; try write(value)
        try storage.removeBlobs(keeping: [value.blob])
    } }
    /// Verifies the open vault's password (a counted attempt) and encrypts the backup with that same password.
    public func export(password: String, csv: Bool) throws -> Data { try serialized {
        guard key != nil else { throw VaultError.locked }
        var candidate = try authenticate(password).key; defer { candidate.resetBytes(in: 0..<candidate.count) }
        if csv { return Data(try VaultCSV.exportRecords(records).utf8) }
        return try VaultCrypto.exportBackup(records, password: password)
    } }
    /// Verifies the open vault's password (a counted attempt) and seals its records for another phone under a new one-time code.
    public func exportTransfer(password: String) throws -> (code: String, data: Data) { try serialized {
        guard key != nil else { throw VaultError.locked }
        var candidate = try authenticate(password).key; defer { candidate.resetBytes(in: 0..<candidate.count) }
        let code = Transfer.newCode()
        return (code, try Transfer.seal(records, code: code))
    } }
    public func merge(_ imported: [VaultRecord]) throws -> [VaultRecord] { try serialized {
        guard key != nil else { throw VaultError.locked }
        // Matched by record id only: a record already in the vault is replaced in place (whole, fields included), the rest are added with their ids.
        let incoming = Dictionary(imported.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), known = Set(records.map(\.id))
        let updated = records.map { incoming[$0.id] ?? $0 } + imported.filter { !known.contains($0.id) }
        try save(FileKeys.keeping(records, in: updated)); return records
    } }
    /// Makes the imported records the whole vault, preserving file-encryption keys that would otherwise be lost.
    public func replaceAll(_ imported: [VaultRecord]) throws -> [VaultRecord] { try serialized {
        guard key != nil else { throw VaultError.locked }
        try save(FileKeys.keeping(records, in: imported)); return records
    } }
    private func erase(_ original: DeviceState) throws {
        lock()
        var tombstone = original
        tombstone.erased = true; tombstone.secret = Data(); tombstone.wrappedKey = Data(); tombstone.salt = Data(); tombstone.decoy = nil; tombstone.decoyChanges = nil
        try write(tombstone) // Deny access even if later cleanup is interrupted.
        try storage.deleteBiometricKey()
        try storage.removeBlobs(keeping: [])
    }
}
