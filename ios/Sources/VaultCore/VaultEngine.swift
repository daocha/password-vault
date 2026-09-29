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
    private func state() throws -> DeviceState? {
        guard let data = try storage.readState() else {
            guard try !storage.hasBlobs() else { throw VaultError.invalid("Protected state is missing. Vault access is refused.") }
            return nil
        }
        let value = try JSONDecoder().decode(DeviceState.self, from: data)
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
        return try JSONDecoder().decode(DeviceState.self, from: data).erased
    } }
    public func resetErasedVault() throws { try serialized {
        guard try isErased() else { throw VaultError.invalid("Only an already-erased vault can be reset without a password.") }
        lock(); try storage.deleteBiometricKey(); try storage.removeBlobs(except: nil); try storage.deleteState()
    } }
    public func remainingAttempts() throws -> Int { try serialized { 10 - (try state()?.attempts ?? 0) } }
    public func lock() { serialized { let count = key?.count ?? 0; key?.resetBytes(in: 0..<count); key = nil; records = [] } }
    public func create(password: String) throws -> [VaultRecord] { try serialized {
        guard try state() == nil else { throw VaultError.invalid("A vault already exists.") }
        try VaultCrypto.requireStrongPassword(password)
        let salt = VaultCrypto.random(16), secret = VaultCrypto.random(32), dataKey = VaultCrypto.random(32)
        var derived = try VaultCrypto.passwordKey(password, salt: salt)
        defer { derived.resetBytes(in: 0..<derived.count) }
        var wrapping = try VaultCrypto.deviceKey(derived, secret: secret)
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        let blob = UUID().uuidString
        let value = DeviceState(salt: salt, secret: secret, wrappedKey: try VaultCrypto.seal(dataKey, key: wrapping, aad: Data("PassVault/key/v1".utf8)), blob: blob)
        try storage.writeBlob(VaultCrypto.seal(Records.encode([]), key: dataKey, aad: Data(blob.utf8)), id: blob)
        // Without its state the new file would block every later attempt ("Protected state is missing"), e.g. when no passcode is set.
        do { try write(value) } catch { try? storage.removeBlobs(except: nil); throw error }
        key = dataKey; records = []; return []
    } }
    private func authenticate(_ password: String) throws -> Data {
        guard var value = try state() else { throw VaultError.locked }
        value.attempts += 1
        try write(value) // Reserve before expensive work; interruption consumes this attempt.
        var derived = try VaultCrypto.passwordKey(password, salt: value.salt)
        defer { derived.resetBytes(in: 0..<derived.count) }
        var wrapping = try VaultCrypto.deviceKey(derived, secret: value.secret)
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        let candidate: Data
        do { candidate = try VaultCrypto.open(value.wrappedKey, key: wrapping, aad: Data("PassVault/key/v1".utf8)) }
        catch VaultError.authentication {
            lock()
            if value.attempts == 10 { try erase(value); throw VaultError.erased }
            throw VaultError.authentication
        }
        value.attempts = 0; try write(value)
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
    public func changePassword(current: String, new: String) throws { try serialized {
        guard key != nil else { throw VaultError.locked }
        try VaultCrypto.requireStrongPassword(new)
        var candidate = try authenticate(current); defer { candidate.resetBytes(in: 0..<candidate.count) }
        guard var value = try state() else { throw VaultError.locked }
        let salt = VaultCrypto.random(16), secret = VaultCrypto.random(32)
        var derived = try VaultCrypto.passwordKey(new, salt: salt); defer { derived.resetBytes(in: 0..<derived.count) }
        var wrapping = try VaultCrypto.deviceKey(derived, secret: secret); defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        value.salt = salt; value.secret = secret
        value.wrappedKey = try VaultCrypto.seal(candidate, key: wrapping, aad: Data("PassVault/key/v1".utf8))
        try write(value)
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
