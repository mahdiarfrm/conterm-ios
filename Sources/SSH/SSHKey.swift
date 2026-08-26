import Foundation

/// A private key you've imported.
///
/// Keys belong to the app, not to a host — you have one `id_rsa` and twelve
/// machines that accept it, so pasting the same key into twelve host records
/// is both tedious and twelve copies of a secret. A host references a key by
/// id; the material itself lives in the Keychain and never in this record.
struct SSHKey: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var format: Format
    /// True when the key is passphrase-protected. Determined at import, so
    /// the connect path knows to ask before it tries.
    var isEncrypted: Bool
    var importedAt: Date = Date()

    enum Format: String, Codable, Sendable {
        case openssh          // -----BEGIN OPENSSH PRIVATE KEY-----
        case rsaPKCS1         // -----BEGIN RSA PRIVATE KEY-----
        case ecPKCS1          // -----BEGIN EC PRIVATE KEY-----
        case dsaPKCS1         // -----BEGIN DSA PRIVATE KEY-----
        case pkcs8            // -----BEGIN PRIVATE KEY-----
        case pkcs8Encrypted   // -----BEGIN ENCRYPTED PRIVATE KEY-----

        var label: String {
            switch self {
            case .openssh: return "OpenSSH"
            case .rsaPKCS1: return "RSA (PEM)"
            case .ecPKCS1: return "ECDSA (PEM)"
            case .dsaPKCS1: return "DSA (PEM)"
            case .pkcs8: return "PKCS#8"
            case .pkcs8Encrypted: return "PKCS#8, encrypted"
            }
        }
    }

    /// What went wrong, in terms someone can act on. "Invalid key" tells you
    /// nothing; "this is the public half" tells you exactly what to do.
    enum ImportError: LocalizedError {
        case looksLikePublicKey
        case notAKey
        case empty

        var errorDescription: String? {
            switch self {
            case .looksLikePublicKey:
                return """
                    That's the public half — the one ending in .pub, which \
                    lives on the server. Import the file without the \
                    extension instead (id_rsa, not id_rsa.pub).
                    """
            case .notAKey:
                return """
                    That file doesn't look like a private key. A private key \
                    starts with a line like -----BEGIN OPENSSH PRIVATE KEY-----.
                    """
            case .empty:
                return "That file is empty."
            }
        }
    }

    /// Inspect key text and work out what it is.
    ///
    /// libssh2 does the real parsing at connect time; this exists so the
    /// import screen can reject the obvious mistakes immediately rather than
    /// letting them surface as an authentication failure days later.
    static func inspect(_ text: String, name: String) throws -> SSHKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }

        // The single most common import mistake, and it fails at auth time
        // with a message that explains nothing.
        if trimmed.hasPrefix("ssh-rsa ") || trimmed.hasPrefix("ssh-ed25519 ")
            || trimmed.hasPrefix("ecdsa-sha2-") || trimmed.hasPrefix("ssh-dss ") {
            throw ImportError.looksLikePublicKey
        }

        let format: Format
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") { format = .openssh }
        else if trimmed.contains("BEGIN RSA PRIVATE KEY") { format = .rsaPKCS1 }
        else if trimmed.contains("BEGIN EC PRIVATE KEY") { format = .ecPKCS1 }
        else if trimmed.contains("BEGIN DSA PRIVATE KEY") { format = .dsaPKCS1 }
        else if trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY") { format = .pkcs8Encrypted }
        else if trimmed.contains("BEGIN PRIVATE KEY") { format = .pkcs8 }
        else { throw ImportError.notAKey }

        return SSHKey(name: name,
                      format: format,
                      isEncrypted: encrypted(trimmed, format: format))
    }

    private static func encrypted(_ text: String, format: Format) -> Bool {
        switch format {
        case .pkcs8Encrypted:
            return true
        case .rsaPKCS1, .ecPKCS1, .dsaPKCS1:
            // Classic PEM announces it in the headers.
            return text.contains("Proc-Type: 4,ENCRYPTED")
        case .pkcs8:
            return false
        case .openssh:
            // The OpenSSH container names its cipher in the body. Decoding
            // the base64 and looking for "none" is cheaper and more reliable
            // than parsing the whole structure, and we only need the one bit.
            let body = text
                .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
                .filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: body) else { return false }
            let head = String(decoding: data.prefix(64), as: UTF8.self)
            return !head.contains("none")
        }
    }
}

/// The imported keys, persisted as JSON. Material lives in the Keychain,
/// keyed by the key's id.
@Observable
@MainActor
final class KeyLibrary {
    static let shared = KeyLibrary()

    private(set) var keys: [SSHKey] = []
    private let url: URL

    init(filename: String = "keys.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)
        load()
    }

    /// Import key text. Throws with something actionable if it isn't a key.
    @discardableResult
    func add(text: String, name: String) throws -> SSHKey {
        let key = try SSHKey.inspect(text, name: name)
        try KeyStore.shared.set(text, for: key.id, kind: .privateKey)
        keys.append(key)
        save()
        return key
    }

    func rename(_ key: SSHKey, to name: String) {
        guard let i = keys.firstIndex(where: { $0.id == key.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keys[i].name = trimmed
        save()
    }

    func delete(_ key: SSHKey) {
        keys.removeAll { $0.id == key.id }
        try? KeyStore.shared.delete(for: key.id)
        save()
    }

    func material(for id: UUID) -> String? {
        KeyStore.shared.get(for: id, kind: .privateKey)
    }

    func key(withID id: UUID) -> SSHKey? { keys.first { $0.id == id } }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SSHKey].self, from: data)
        else { return }
        keys = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
