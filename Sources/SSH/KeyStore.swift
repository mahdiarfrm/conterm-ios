import Foundation
import Security
import LocalAuthentication

/// Keychain storage for host secrets.
///
/// Conterm on macOS stores no credentials at all — `grep -rn "Keychain\|SecItem"`
/// over its 47k lines returns nothing, because authentication is entirely
/// delegated to the system `ssh` binary and the user's agent. On iOS there is
/// no agent and no ssh binary, so the app holds the secrets, and where it puts
/// them matters.
///
/// Everything here is `WhenUnlockedThisDeviceOnly`: a terminal credential
/// should not ride an iCloud backup to another device, and should not be
/// readable while the phone is locked.
struct KeyStore {
    static let shared = KeyStore()

    private let service = "dev.conterm.ios.ssh"

    enum Kind: String {
        case password
        case privateKey
        case passphrase
    }

    private func account(_ id: UUID, _ kind: Kind) -> String {
        "\(id.uuidString):\(kind.rawValue)"
    }

    // MARK: - Read / write

    func set(_ value: String, for id: UUID, kind: Kind) throws {
        let acct = account(id, kind)
        guard !value.isEmpty else { try delete(for: id, kind: kind); return }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    func get(for id: UUID, kind: Kind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func delete(for id: UUID, kind: Kind) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychain(status)
        }
    }

    /// Remove every secret belonging to a host. Called when the host is
    /// deleted, so nothing is orphaned in the Keychain.
    func delete(for id: UUID) throws {
        for kind in [Kind.password, .privateKey, .passphrase] {
            try delete(for: id, kind: kind)
        }
    }

    // MARK: - Assembling credentials

    /// Build the credentials for a connection, reading whatever the host's
    /// auth method needs out of the Keychain.
    func credentials(for host: Host) -> SSHCredentials? {
        switch host.auth {
        case .password:
            guard let password = get(for: host.id, kind: .password) else { return nil }
            return SSHCredentials(address: host.address, method: .password(password))

        case .privateKey:
            guard let key = get(for: host.id, kind: .privateKey) else { return nil }
            return SSHCredentials(
                address: host.address,
                method: .privateKey(private: key,
                                    public: nil,
                                    passphrase: get(for: host.id, kind: .passphrase)))
        }
    }

    func hasSecret(for host: Host) -> Bool {
        switch host.auth {
        case .password: return get(for: host.id, kind: .password) != nil
        case .privateKey: return get(for: host.id, kind: .privateKey) != nil
        }
    }
}

enum KeyStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(message.map { ": \($0)" } ?? "")"
        }
    }
}
