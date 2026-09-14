import CryptoKit
import Foundation

/// Makes an SSH key on the phone.
///
/// Ed25519 only: the one type every current sshd accepts, whose private
/// half is thirty-two bytes, and which CryptoKit produces without a
/// library. Written in the OpenSSH private key format, unencrypted, which
/// is what the key library already imports and libssh2 already reads; the
/// Keychain does the protecting.
enum SSHKeyGen {
    struct Generated {
        /// `-----BEGIN OPENSSH PRIVATE KEY-----`, for the library.
        let privateKey: String
        /// `ssh-ed25519 AAAA… comment`, for `authorized_keys`.
        let publicLine: String
        /// The wire-format public key, for a fingerprint or a code.
        let publicBlob: Data
    }

    static func ed25519(comment: String) -> Generated {
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation
        let pub = key.publicKey.rawRepresentation
        let type = Data("ssh-ed25519".utf8)

        let publicBlob = string(type) + string(pub)

        // The private section: two matching check words, the key again,
        // the seed with the public key after it, the comment, then padding
        // 1, 2, 3… up to the cipher block size, which for "none" is 8.
        let check = UInt32.random(in: 0...UInt32.max)
        var priv = word(check) + word(check)
        priv += string(type) + string(pub) + string(seed + pub) + string(Data(comment.utf8))
        var pad: UInt8 = 1
        while priv.count % 8 != 0 { priv.append(pad); pad += 1 }

        var body = Data("openssh-key-v1".utf8) + Data([0])
        body += string(Data("none".utf8)) + string(Data("none".utf8)) + string(Data())
        body += word(1)
        body += string(publicBlob) + string(priv)

        let base64 = body.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
        return Generated(privateKey: pem,
                         publicLine: "ssh-ed25519 \(publicBlob.base64EncodedString()) \(comment)",
                         publicBlob: publicBlob)
    }

    /// `SHA256:…` as ssh-keygen prints it, no padding.
    static func fingerprint(of blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func word(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private static func string(_ data: Data) -> Data {
        word(UInt32(data.count)) + data
    }
}
