import SwiftUI

/// Ad-hoc connect: type `user@host` and go, the way you would at a shell.
///
/// Saving a host record first is the right flow for a machine you use daily
/// and pure friction for one you touch once. Nothing here is persisted unless
/// you ask for it — the credential is held in memory for the session and
/// never reaches the Keychain.
struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss

    let app: Ghostty.App
    let store: HostStore
    /// Handed the live session so the list can push it.
    let onConnect: (TerminalSession) -> Void

    @State private var target = ""
    @State private var secret = ""
    @State private var passphrase = ""
    @State private var auth: Host.AuthKind = .password
    @State private var save = false
    @State private var error: String?
    @State private var library = KeyLibrary.shared
    @State private var keyID: UUID?
    @State private var managingKeys = false

    /// `user@host:port`, `user@host`, or bare `host`. Port and user are
    /// optional; a missing user is the one thing we cannot guess, since the
    /// phone's own username means nothing to the far end.
    private var parsed: (user: String, host: String, port: Int)? {
        let t = target.trimmed
        guard !t.isEmpty else { return nil }

        var rest = t
        var user = ""
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[rest.startIndex..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port = 22
        // Only treat a trailing :N as a port — an IPv6 literal has colons too.
        if let colon = rest.lastIndex(of: ":"),
           rest.filter({ $0 == ":" }).count == 1,
           let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) {
            port = p
            rest = String(rest[rest.startIndex..<colon])
        }
        guard !user.isEmpty, !rest.isEmpty else { return nil }
        return (user, rest, port)
    }

    private var isValid: Bool {
        guard parsed != nil else { return false }
        switch auth {
        case .password: return !secret.isEmpty
        case .privateKey: return keyID != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("user@host", text: $target)
                        .font(.system(size: 16, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Target")
                } footer: {
                    Text("root@10.0.0.4, deploy@example.com:2222")
                        .font(.system(size: 11, design: .monospaced))
                }

                Section("Authentication") {
                    Picker("Method", selection: $auth) {
                        ForEach(Host.AuthKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch auth {
                    case .password:
                        SecureField("Password", text: $secret)
                    case .privateKey:
                        if library.keys.isEmpty {
                            Button { managingKeys = true } label: {
                                Label("Import a key", systemImage: "key.fill")
                            }
                        } else {
                            Picker("Key", selection: $keyID) {
                                Text("None").tag(UUID?.none)
                                ForEach(library.keys) { key in
                                    Text(key.name).tag(UUID?.some(key.id))
                                }
                            }
                            if let id = keyID, library.key(withID: id)?.isEncrypted == true {
                                SecureField("Key passphrase", text: $passphrase)
                            }
                            Button { managingKeys = true } label: {
                                Label("Manage keys", systemImage: "key")
                            }
                        }
                    }
                }

                Section {
                    Toggle("Save to Hosts", isOn: $save)
                } footer: {
                    Text(save
                         ? "The credential goes to the Keychain."
                         : "Nothing is written to disk. The credential lives only as long as this session.")
                }

                if let error {
                    Text(error)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.Status.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground.ignoresSafeArea())
            .sheet(isPresented: $managingKeys) { KeyLibraryView() }
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { connect() }.disabled(!isValid)
                }
            }
        }
        .tint(Theme.accentOnDark)
    }

    private func connect() {
        guard let p = parsed else {
            error = "Enter a target as user@host."
            return
        }

        var host = Host(alias: p.host, hostname: p.host,
                        port: p.port, username: p.user, auth: auth)
        host.keyID = keyID

        let method: SSHCredentials.Method
        switch auth {
        case .password:
            method = .password(secret)
        case .privateKey:
            guard let id = keyID, let material = library.material(for: id) else {
                error = "That key could not be read back from the Keychain."
                return
            }
            method = .privateKey(private: material, public: nil,
                                 passphrase: passphrase.isEmpty ? nil : passphrase)
        }

        if save {
            do {
                if auth == .password {
                    try KeyStore.shared.set(secret, for: host.id, kind: .password)
                }
                if !passphrase.isEmpty, let id = keyID {
                    try KeyStore.shared.set(passphrase, for: id, kind: .passphrase)
                }
                host.lastConnectedAt = Date()
                store.add(host)
            } catch {
                self.error = error.localizedDescription
                return
            }
        }

        let session = TerminalSession(host: host, app: app)
        session.connect(credentials: SSHCredentials(address: host.address, method: method))
        onConnect(session)
        dismiss()
    }
}
