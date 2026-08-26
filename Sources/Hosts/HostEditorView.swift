import SwiftUI

/// Add or edit a host.
///
/// Secrets are written straight to the Keychain on save and are never held in
/// the `Host` record, so a host that syncs or gets exported later carries no
/// credentials with it.
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let store: HostStore
    /// nil = creating a new host.
    var existing: Host?

    @State private var host: Host
    @State private var secret: String = ""
    @State private var passphrase: String = ""
    @State private var error: String?
    @State private var library = KeyLibrary.shared
    @State private var managingKeys = false

    init(store: HostStore, existing: Host? = nil) {
        self.store = store
        self.existing = existing
        _host = State(initialValue: existing ?? Host())
    }

    private var isValid: Bool {
        guard !host.hostname.trimmed.isEmpty,
              !host.username.trimmed.isEmpty,
              (1...65535).contains(host.port) else { return false }
        // Choosing key auth without choosing a key would save a host that
        // cannot connect.
        if host.auth == .privateKey && host.keyID == nil { return false }
        return true
    }

    private var selectedKeyNeedsPassphrase: Bool {
        guard let id = host.keyID else { return false }
        return library.key(withID: id)?.isEncrypted ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledField("Name", text: $host.alias,
                                 placeholder: host.hostname.isEmpty ? "web-01" : host.hostname)
                    LabeledField("Host", text: $host.hostname, placeholder: "10.0.0.4",
                                 keyboard: .URL)
                    LabeledField("User", text: $host.username, placeholder: "root")
                    HStack {
                        Text("Port").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        TextField("22", value: $host.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section("Authentication") {
                    Picker("Method", selection: $host.auth) {
                        ForEach(Host.AuthKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch host.auth {
                    case .password:
                        SecureField("Password", text: $secret)
                            .textContentType(.password)
                    case .privateKey:
                        if library.keys.isEmpty {
                            Button {
                                managingKeys = true
                            } label: {
                                Label("Import a key", systemImage: "key.fill")
                            }
                            Text("Import id_rsa or id_ed25519 once and use it on any host.")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Picker("Key", selection: $host.keyID) {
                                Text("None").tag(UUID?.none)
                                ForEach(library.keys) { key in
                                    Text(key.name).tag(UUID?.some(key.id))
                                }
                            }
                            Button {
                                managingKeys = true
                            } label: {
                                Label("Manage keys", systemImage: "key")
                            }
                            if selectedKeyNeedsPassphrase {
                                SecureField("Key passphrase", text: $passphrase)
                            }
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.Status.danger)
                    }
                }

                if existing != nil {
                    Section {
                        Button("Delete host", role: .destructive) {
                            store.delete(host)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle(existing == nil ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
            .onAppear(perform: loadExistingSecret)
            .sheet(isPresented: $managingKeys) { KeyLibraryView() }
        }
        .tint(Theme.accentOnDark)
    }

    private func loadExistingSecret() {
        guard let existing else { return }
        // Show that a secret exists without reading it back into the form —
        // a password field pre-filled with the real password is a way to
        // leak it over someone's shoulder.
        if KeyStore.shared.hasSecret(for: existing) && existing.auth == .password {
            secret = ""
        }
    }

    private func save() {
        var h = host
        h.alias = h.alias.trimmed.isEmpty ? h.hostname.trimmed : h.alias.trimmed
        h.hostname = h.hostname.trimmed
        h.username = h.username.trimmed

        do {
            if h.auth == .password && !secret.isEmpty {
                try KeyStore.shared.set(secret, for: h.id, kind: .password)
            }
            if !passphrase.isEmpty, let keyID = h.keyID {
                try KeyStore.shared.set(passphrase, for: keyID, kind: .passphrase)
            }
        } catch {
            self.error = error.localizedDescription
            return
        }

        if existing == nil { store.add(h) } else { store.update(h) }
        dismiss()
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default

    init(_ label: String, text: Binding<String>,
         placeholder: String = "", keyboard: UIKeyboardType = .default) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.keyboard = keyboard
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
