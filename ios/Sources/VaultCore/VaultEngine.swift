import Foundation

// The adapter must persist state atomically in protected storage, never ordinary preferences.
public protocol VaultStorage: AnyObject {
    func readState() throws -> Data?
    func writeState(_ data: Data) throws
    func deleteState() throws
    func readBlob(_ id: String) throws -> Data
    func writeBlob(_ data: Data, id: String) throws
    func removeBlobs(except id: String?) throws
    func hasBlobs() throws -> Bool
    func saveBiometricKey(_ data: Data) throws
    func readBiometricKey() throws -> Data
    func deleteBiometricKey() throws
}
struct DeviceState: Codable {
    var version = 1
    var attempts = 0
    var erased = false
    var salt: Data
    var secret: Data
    var wrappedKey: Data
    var blob: String
}
public final class VaultEngine: @unchecked Sendable {
    private let storage: VaultStorage
    private let mutex = NSRecursiveLock()
    private var key: Data?
    private var records = [VaultRecord]()
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
        return value
    }
    private func write(_ value: DeviceState) throws { try storage.writeState(JSONEncoder().encode(value)) }
    public func exists() throws -> Bool { try serialized { try state() != nil } }
    /// True after erasure, and also when ciphertext exists without its protected state (e.g. the device passcode was removed,
    /// which deletes the Keychain items): nothing can decrypt it, so it may be reset like an erased vault.
    public func isErased() throws -> Bool { try serialized {
        guard let data = try storage.readState() else { return try storage.hasBlobs() }
        return try Self.decodeState(data).erased
    } }
    public func resetErasedVault() throws { try serialized {
        guard try isErased() else { throw VaultError.invalid("Only an already-erased vault can be reset without a password.") }
        lock(); try storage.deleteBiometricKey(); try storage.removeBlobs(except: nil); try storage.deleteState()
    } }
    public func remainingAttempts() throws -> Int { try serialized { 10 - (try state()?.attempts ?? 0) } }
    public func lock() { serialized { let count = key?.count ?? 0; key?.resetBytes(in: 0..<count); key = nil; records = [] } }
    /// Wraps `dataKey` under `password` with a fresh salt and device secret.
    private func wrap(_ password: String, dataKey: Data) throws -> (salt: Data, secret: Data, wrapped: Data) {
        let salt = VaultCrypto.random(16), secret = VaultCrypto.random(32)
        var derived = try VaultCrypto.passwordKey(password, salt: salt)
        defer { derived.resetBytes(in: 0..<derived.count) }
        var wrapping = try VaultCrypto.deviceKey(derived, secret: secret)
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        return (salt, secret, try VaultCrypto.seal(dataKey, key: wrapping, aad: Data("PassVault/key/v1".utf8)))
    }
    public func create(password: String) throws -> [VaultRecord] { try serialized {
        guard try state() == nil else { throw VaultError.invalid("A vault already exists.") }
        try VaultCrypto.requireStrongPassword(password)
        let dataKey = VaultCrypto.random(32), wrapped = try wrap(password, dataKey: dataKey)
        let blob = UUID().uuidString
        let value = DeviceState(salt: wrapped.salt, secret: wrapped.secret, wrappedKey: wrapped.wrapped, blob: blob)
        try storage.writeBlob(VaultCrypto.seal(Records.encode([]), key: dataKey, aad: Data(blob.utf8)), id: blob)
        // Without its state the new file would block every later attempt ("Protected state is missing"), e.g. when no passcode is set.
        do { try write(value) } catch { try? storage.removeBlobs(except: nil); throw error }
        key = dataKey; records = []; return []
    } }
    private func authenticate(_ password: String) throws -> Data {
        guard var value = try state() else { throw VaultError.locked }
        value.attempts += 1
        try write(value) // Reserve before expensive work; interruption consumes this attempt.
        // Vaults made before passwords were normalized are keyed from the text exactly as typed. Accept that form once and re-wrap in the
        // normalized form below. Both forms count as one attempt.
        var found: Data?, legacy = false
        for raw in PasswordText.differs(password) ? [false, true] : [false] {
            var derived = try VaultCrypto.passwordKey(password, salt: value.salt, legacyEncoding: raw)
            defer { derived.resetBytes(in: 0..<derived.count) }
            var wrapping = try VaultCrypto.deviceKey(derived, secret: value.secret)
            defer { wrapping.resetBytes(in: 0..<wrapping.count) }
            do { found = try VaultCrypto.open(value.wrappedKey, key: wrapping, aad: Data("PassVault/key/v1".utf8)); legacy = raw; break }
            catch VaultError.authentication { continue }
        }
        guard let candidate = found else {
            lock()
            if value.attempts == 10 { try erase(value); throw VaultError.erased }
            throw VaultError.authentication
        }
        value.attempts = 0
        if legacy { let wrapped = try wrap(password, dataKey: candidate); value.salt = wrapped.salt; value.secret = wrapped.secret; value.wrappedKey = wrapped.wrapped }
        try write(value)
        return candidate
    }
    private func load(_ candidate: Data) throws -> [VaultRecord] {
        guard let value = try state() else { throw VaultError.locked }
        var plaintext = try VaultCrypto.open(storage.readBlob(value.blob), key: candidate, aad: Data(value.blob.utf8))
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let loaded = try Records.decode(plaintext)
        key = candidate; records = loaded; return loaded
    }
    public func unlock(password: String) throws -> [VaultRecord] { try serialized { try load(authenticate(password)) } }
    public func unlockBiometric() throws -> [VaultRecord] { try serialized {
        guard try state() != nil else { throw VaultError.locked }
        // Successful biometrics never reset the app-password attempt counter.
        return try load(storage.readBiometricKey())
    } }
    public func enableBiometrics(password: String) throws { try serialized {
        var candidate = try authenticate(password); defer { candidate.resetBytes(in: 0..<candidate.count) }
        try storage.saveBiometricKey(candidate)
    } }
    public func save(_ updated: [VaultRecord]) throws { try serialized {
        guard let key, var value = try state() else { throw VaultError.locked }
        let blob = UUID().uuidString
        try storage.writeBlob(VaultCrypto.seal(Records.encode(updated), key: key, aad: Data(blob.utf8)), id: blob)
        value.blob = blob; try write(value) // Commit pointer only after durable ciphertext.
        records = updated
        try storage.removeBlobs(except: blob)
    } }
    /// Also replaces the data key and re-encrypts the vault, so nothing derived from the old password or old state can open future data.
    public func changePassword(current: String, new: String) throws { try serialized {
        guard key != nil else { throw VaultError.locked }
        try VaultCrypto.requireStrongPassword(new)
        var proven = try authenticate(current); proven.resetBytes(in: 0..<proven.count) // the vault is unlocked, so the old data key is not needed again
        guard var value = try state() else { throw VaultError.locked }
        let previous = value.blob, blob = UUID().uuidString, dataKey = VaultCrypto.random(32)
        var plaintext = try Records.encode(records); defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        try storage.writeBlob(VaultCrypto.seal(plaintext, key: dataKey, aad: Data(blob.utf8)), id: blob)
        do {
            let wrapped = try wrap(new, dataKey: dataKey)
            // The biometric copy holds the old data key. Remove it before the commit so it cannot outlive the state that made it valid.
            try storage.deleteBiometricKey()
            value.salt = wrapped.salt; value.secret = wrapped.secret; value.wrappedKey = wrapped.wrapped; value.blob = blob
            try write(value)
        } catch { try? storage.removeBlobs(except: previous); throw error }
        let count = key?.count ?? 0; key?.resetBytes(in: 0..<count); key = dataKey
        try storage.removeBlobs(except: blob)
    } }
    public func export(password: String, backupPassword: String?, csv: Bool) throws -> Data { try serialized {
        guard key != nil else { throw VaultError.locked }
        var candidate = try authenticate(password); defer { candidate.resetBytes(in: 0..<candidate.count) }
        if csv { return Data(try VaultCSV.exportRecords(records).utf8) }
        guard let backupPassword else { throw VaultError.invalid("A backup password is required.") }
        return try VaultCrypto.exportBackup(records, password: backupPassword)
    } }
    public func merge(_ imported: [VaultRecord]) throws -> [VaultRecord] { try serialized {
        guard key != nil else { throw VaultError.locked }
        // Append with new identifiers; importing never silently replaces an existing record.
        let copies = imported.map { record -> VaultRecord in var copy = record; copy.id = UUID().uuidString; return copy }
        let updated = records + copies; try save(updated); return updated
    } }
    private func erase(_ original: DeviceState) throws {
        lock()
        var tombstone = original
        tombstone.erased = true; tombstone.secret = Data(); tombstone.wrappedKey = Data(); tombstone.salt = Data()
        try write(tombstone) // Deny access even if later cleanup is interrupted.
        try storage.deleteBiometricKey()
        try storage.removeBlobs(except: nil)
    }
}
