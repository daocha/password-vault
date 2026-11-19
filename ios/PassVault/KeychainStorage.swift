import Foundation
import Security
import LocalAuthentication
import VaultCore

/// The vault the app and its AutoFill extension share. Both open it from the app group's container (the vault files) and the same group
/// as Keychain access group (the protected state and the biometric key). Vaults made before AutoFill are in the app's own container and
/// Keychain group; the app moves them over once (`KeychainStorage.init`). Until then, or when the group is not available, the vault stays
/// where it was and only the app opens it.
enum SharedVault {
    /// group.<the app's bundle ID>. The extension's bundle ID is the app's with ".autofill" added.
    static var group: String {
        let id = Bundle.main.bundleIdentifier ?? "app.passvault.mobile"
        return "group." + (id.hasSuffix(".autofill") ? String(id.dropLast(".autofill".count)) : id)
    }
    /// Written once the vault is in the shared container: from then on the app and AutoFill open it there.
    static let movedMarker = "moved"
    /// The folder in the app group's container, or nil when the app group is not available.
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("PassVault", isDirectory: true)
    }
    /// Nonsecret preferences AutoFill follows (language and appearance); the app copies them here.
    static var preferences: UserDefaults? { UserDefaults(suiteName: group) }
}

final class KeychainStorage: VaultStorage {
    enum Role { case app, autofill }
    /// AutoFill before the app has moved the vault where AutoFill can open it.
    struct NotShared: LocalizedError { var errorDescription: String? { "Open PassVault once, then try AutoFill again." } }

    private static let serviceName = "app.passvault.keys.v1"
    private let service = KeychainStorage.serviceName
    private let directory: URL
    /// The shared Keychain access group, once the vault is shared; nil while it is the app's alone.
    private let sharedGroup: String?
    /// Kept by the app and AutoFill around every storage transaction of a shared vault (see `VaultStorage.exclusive`).
    private let crossProcess: FileLock?
    /// The text Face ID or Touch ID shows, in the app's language.
    private let reason: () -> String
    /// Whether AutoFill can open this vault.
    var shared: Bool { sharedGroup != nil }

    /// `protectedDataAvailable`: whether the device has been unlocked (a prewarmed launch can come before that); the vault is moved only
    /// then. `keepAlive(true)`/`(false)`: the app keeps running in the background while it holds the shared lock, because iOS stops an app
    /// that is suspended holding a lock in a shared container.
    init(role: Role = .app, protectedDataAvailable: Bool = true, keepAlive: ((Bool) -> Void)? = nil,
         reason: @escaping () -> String = { "Unlock your password vault" }) throws {
        self.reason = reason
        let manager = FileManager.default
        let group = SharedVault.group, shared = SharedVault.folder
        let moved = shared.map { manager.fileExists(atPath: $0.appendingPathComponent(SharedVault.movedMarker).path) } ?? false
        if role == .autofill {
            guard let shared, moved else { throw NotShared() }
            directory = shared; sharedGroup = group
            crossProcess = FileLock(path: shared.appendingPathComponent("lock").path, keepAlive: nil)
            return
        }
        let own = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PassVault", isDirectory: true)
        try Self.prepare(own, protection: .complete)
        // Keychain items outlive an uninstall but the vault files do not. On the first launch of a fresh install (no marker and
        // no ciphertext), drop stale items so a reinstalled app starts over instead of finding state that points at missing files.
        // An existing install that predates the marker keeps its vault and just gets the marker.
        let marker = own.appendingPathComponent("installed")
        if !manager.fileExists(atPath: marker.path) && !moved {
            if try !Self.hasVaultFiles(own) && !(shared.map { (try? Self.hasVaultFiles($0)) ?? false } ?? false) {
                for account in ["state", "biometric"] {
                    // No access group: removes the item from every group this app can reach.
                    let status = SecItemDelete(Self.query(Self.serviceName, account) as CFDictionary)
                    guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.invalid("Could not reset protected storage (\(status)).") }
                }
            }
        }
        // Empty and nonsecret, so it may be written during a prewarmed launch before the first unlock.
        if !manager.fileExists(atPath: marker.path) { try Data().write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }

        if let shared, moved || (protectedDataAvailable && Self.move(service: Self.serviceName, from: own, to: shared, group: group)) {
            directory = shared; sharedGroup = group
            crossProcess = FileLock(path: shared.appendingPathComponent("lock").path, keepAlive: keepAlive)
            // Copies left by a move that stopped before it could remove them; the vault opens from the shared folder now.
            if moved { try? Self.removeVaultFiles(in: own, keeping: []) }
        } else {
            directory = own; sharedGroup = nil; crossProcess = nil
        }
    }

    // MARK: Moving the vault where AutoFill can open it

    /// Copies the vault files to the shared folder, moves the protected state to the shared Keychain group, then marks the vault as
    /// moved and removes the old files. Any step that fails leaves the vault where it was (returns false); a later launch tries again.
    /// The biometric key cannot be read without Face ID or Touch ID: it moves the next time it unlocks the app (`get`).
    private static func move(service: String, from own: URL, to shared: URL, group: String) -> Bool {
        guard groupKeychainWorks(service: service, group: group) else { return false }
        var copied = [URL]()
        do {
            try prepare(shared, protection: .completeUntilFirstUserAuthentication)
            for file in try FileManager.default.contentsOfDirectory(at: own, includingPropertiesForKeys: nil) where file.pathExtension == "vault" {
                let target = shared.appendingPathComponent(file.lastPathComponent)
                try Data(contentsOf: file).write(to: target, options: [.atomic, .completeFileProtection]); copied.append(target)
            }
            try moveItem(service: service, account: "state", to: group)
            try Data().write(to: shared.appendingPathComponent(SharedVault.movedMarker), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // The state may already be in the shared group: that is harmless, both apps read it from either group, and the old files
            // are still where the app opens them.
            for file in copied { try? FileManager.default.removeItem(at: file) }
            return false
        }
        try? removeVaultFiles(in: own, keeping: [])
        return true
    }
    /// Whether this build may use the shared Keychain group (an unsigned or differently provisioned build may not).
    private static func groupKeychainWorks(service: String, group: String) -> Bool {
        var probe = query(service, "group-check")
        probe[kSecAttrAccessGroup as String] = group
        let status = SecItemAdd(probe.merging([kSecValueData as String: Data(), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return false }
        SecItemDelete(probe as CFDictionary)
        return true
    }
    /// Puts the item in `group` (a copy there, then the old one removed), unless it is there already. If a copy is already in the group
    /// (an earlier move stopped half way), only the old ones are removed: both were always written together, so they hold the same data.
    private static func moveItem(service: String, account: String, to group: String) throws {
        var list = query(service, account)
        list[kSecReturnAttributes as String] = true
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: CFTypeRef?
        let status = SecItemCopyMatching(list as CFDictionary, &found)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = found as? [[String: Any]] else { throw VaultError.invalid("Could not read protected state (\(status)).") }
        let groups = items.compactMap { $0[kSecAttrAccessGroup as String] as? String }
        guard groups.count == items.count else { throw VaultError.invalid("Could not read protected state.") }
        if !groups.contains(group) {
            var read = query(service, account)
            read[kSecAttrAccessGroup as String] = groups[0]
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var data: CFTypeRef?
            let readStatus = SecItemCopyMatching(read as CFDictionary, &data)
            guard readStatus == errSecSuccess, let value = data as? Data else { throw VaultError.invalid("Could not read protected state (\(readStatus)).") }
            var add = query(service, account)
            add[kSecAttrAccessGroup as String] = group
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw VaultError.invalid("Could not share protected state (\(addStatus)).") }
        }
        for old in Set(groups) where old != group {
            var delete = query(service, account)
            delete[kSecAttrAccessGroup as String] = old
            let deleteStatus = SecItemDelete(delete as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw VaultError.invalid("Could not share protected state (\(deleteStatus)).") }
        }
    }

    // MARK: Files

    private static func prepare(_ folder: URL, protection: FileProtectionType) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
        var url = folder, values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private static func hasVaultFiles(_ folder: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).contains { $0.pathExtension == "vault" }
    }
    private static func removeVaultFiles(in folder: URL, keeping ids: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "vault" && !ids.contains(url.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Keychain

    /// No access group: reads, updates and deletes find the item in any group this process can reach (the app's own, or the shared one).
    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    private func query(_ account: String) -> [String: Any] { Self.query(service, account) }
    /// A new item goes to the shared group once the vault is shared.
    private func adding(_ account: String) -> [String: Any] {
        var item = query(account)
        if let sharedGroup { item[kSecAttrAccessGroup as String] = sharedGroup }
        return item
    }
    private func get(_ account: String, biometric: Bool = false) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.localizedReason = reason()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        if biometric { request[kSecUseAuthenticationContext as String] = context }
        defer { context.invalidate() }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        // The user closed the Face ID / Touch ID prompt (to type the password instead): not an error to show.
        if biometric && status == errSecUserCanceled { throw VaultError.cancelled }
        guard status == errSecSuccess, let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else {
            throw VaultError.invalid("Protected storage is unavailable or authentication was cancelled (\(status)).")
        }
        // A biometric key from before the vault was shared: now that Face ID or Touch ID released it, put it where AutoFill finds it.
        if biometric, let sharedGroup, let old = item[kSecAttrAccessGroup as String] as? String, old != sharedGroup { shareBiometricKey(data, from: old, to: sharedGroup) }
        return data
    }
    /// Adds a copy in the shared group first and removes the old one only once that worked, so a failure never loses the key.
    private func shareBiometricKey(_ data: Data, from old: String, to group: String) {
        var error: Unmanaged<CFError>?
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else { return }
        var add = query("biometric")
        add[kSecAttrAccessGroup as String] = group; add[kSecValueData as String] = data; add[kSecAttrAccessControl as String] = acl
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return }
        var delete = query("biometric")
        delete[kSecAttrAccessGroup as String] = old
        SecItemDelete(delete as CFDictionary)
    }
    private func put(_ account: String, _ data: Data, biometric: Bool = false) throws {
        let base = query(account)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if biometric {
            var error: Unmanaged<CFError>?
            guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else { throw VaultError.invalid("Biometric protection is unavailable.") }
            attributes[kSecAttrAccessControl as String] = acl
        } else { attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
        var status: OSStatus
        if biometric {
            // Replace, never update: an item invalidated by a biometric enrollment change cannot be updated in place.
            status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.invalid("Could not replace biometric key (\(status)).") }
            status = SecItemAdd(adding(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        } else {
            status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(adding(account).merging(attributes) { _, new in new } as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw VaultError.invalid("Could not commit protected state. Set a device passcode first (\(status)).") }
    }

    // MARK: VaultStorage

    func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        guard let crossProcess else { return try body() }
        return try crossProcess.run(body)
    }
    func readState() throws -> Data? { try get("state") }
    func writeState(_ data: Data) throws { try put("state", data) }
    func deleteState() throws {
        let status = SecItemDelete(query("state") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.invalid("Could not reset erased state.") }
    }
    private func path(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw VaultError.invalid("Invalid vault identifier.") }
        return directory.appendingPathComponent(id + ".vault")
    }
    func readBlob(_ id: String) throws -> Data {
        let url = try path(id)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= Records.maxBytes + 40 else { throw VaultError.invalid("Vault file is too large.") }
        return try Data(contentsOf: url)
    }
    func writeBlob(_ data: Data, id: String) throws { try data.write(to: path(id), options: [.atomic, .completeFileProtection]) }
    func hasBlobs() throws -> Bool { try Self.hasVaultFiles(directory) }
    func removeBlobs(keeping ids: Set<String>) throws { try Self.removeVaultFiles(in: directory, keeping: ids) }
    func saveBiometricKey(_ data: Data) throws {
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { throw VaultError.invalid("Enroll Face ID or Touch ID in Settings first.") }
        try put("biometric", data, biometric: true)
    }
    func readBiometricKey() throws -> Data {
        guard let data = try get("biometric", biometric: true) else { throw VaultError.invalid("Unlock with your password and enable biometrics first.") }
        return data
    }
    func hasBiometricKey() throws -> Bool {
        var request = query("biometric")
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &attributes)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess || status == errSecInteractionNotAllowed else { throw VaultError.invalid("Biometric protection is unavailable.") }
        return true
    }
    func deleteBiometricKey() throws {
        let status = SecItemDelete(query("biometric") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.invalid("Could not remove biometric key (\(status)).") }
    }
}
