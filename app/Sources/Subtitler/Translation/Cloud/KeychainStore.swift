import Foundation
import Security

/// Where API keys live. The app only ever holds a key while it builds a request.
protocol SecretStore: Sendable {
    func read(_ name: String) -> String?
    func save(_ secret: String, for name: String) throws
    func delete(_ name: String) throws
}

extension SecretStore {
    /// "••••1234": all the UI may ever show of a saved key.
    func hint(_ name: String) -> String? {
        read(name).map { "••••" + String($0.suffix(4)) }
    }
}

enum SecretStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "The Keychain refused the change (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."
        }
    }
}

/// API keys in the macOS Keychain: one generic password per provider, only readable while
/// the Mac is unlocked, never synced to other devices (iCloud Keychain) or backups.
struct KeychainStore: SecretStore {
    static let app = KeychainStore(servicePrefix: "com.syantxhub.subtitler.cloud.")

    let servicePrefix: String
    private static let account = "api-key"

    func read(_ name: String) -> String? {
        for dataProtection in [true, false] {
            var query = base(name, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let secret = String(data: data, encoding: .utf8) {
                return secret
            }
        }
        return nil
    }

    func save(_ secret: String, for name: String) throws {
        try delete(name)
        let data = Data(secret.utf8)
        var status = add(name, data, dataProtection: true)
        // The data-protection keychain needs a keychain-access-groups entitlement, which
        // ad-hoc signed builds don't have; the login keychain works everywhere.
        if status == errSecMissingEntitlement { status = add(name, data, dataProtection: false) }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    func delete(_ name: String) throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(base(name, dataProtection: dataProtection) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
                throw SecretStoreError.keychain(status)
            }
        }
    }

    private func add(_ name: String, _ data: Data, dataProtection: Bool) -> OSStatus {
        var item = base(name, dataProtection: dataProtection)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Subtitler API key (\(name))"
        return SecItemAdd(item as CFDictionary, nil)
    }

    private func base(_ name: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + name,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

/// For tests and `--snapshot`: nothing touches the real Keychain.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    init(_ secrets: [String: String] = [:]) { self.secrets = secrets }

    func read(_ name: String) -> String? { lock.withLock { secrets[name] } }
    func save(_ secret: String, for name: String) throws { lock.withLock { secrets[name] = secret } }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
}
