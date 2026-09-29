import Foundation
import Security
import LocalAuthentication
import VaultCore

final class KeychainStorage: VaultStorage {
    private let service = "app.passvault.keys.v1"
    private let directory: URL
    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PassVault", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var url = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    private func get(_ account: String, biometric: Bool = false) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.localizedReason = "Unlock your password vault"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        if biometric { request[kSecUseAuthenticationContext as String] = context }
        defer { context.invalidate() }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.invalid("Protected storage is unavailable or authentication was cancelled (\(status)).") }
        return data
    }
    private func put(_ account: String, _ data: Data, biometric: Bool = false) throws {
        let base = query(account)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if biometric {
            var error: Unmanaged<CFError>?
            guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else { throw VaultError.invalid("Biometric protection is unavailable.") }
            attributes[kSecAttrAccessControl as String] = acl
        } else { attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError.invalid("Could not commit protected state. Set a device passcode first (\(status)).") }
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
    func hasBlobs() throws -> Bool { try !FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty }
    func removeBlobs(except id: String?) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "vault" && url.deletingPathExtension().lastPathComponent != id {
            try FileManager.default.removeItem(at: url)
        }
    }
    func saveBiometricKey(_ data: Data) throws {
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { throw VaultError.invalid("Enroll Face ID or Touch ID in Settings first.") }
        try put("biometric", data, biometric: true)
    }
    func readBiometricKey() throws -> Data {
        guard let data = try get("biometric", biometric: true) else { throw VaultError.invalid("Unlock with your password and enable biometrics first.") }
        return data
    }
    func deleteBiometricKey() throws {
        let status = SecItemDelete(query("biometric") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.invalid("Could not remove biometric key (\(status)).") }
    }
}
