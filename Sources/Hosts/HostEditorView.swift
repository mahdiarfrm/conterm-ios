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

    init(store: HostStore, existing: Host? = nil) {
        self.store = store
        self.existing = existing
        _host = State(initialValue: existing ?? Host())
    }

    private var isValid: Bool {
        !host.hostname.trimmed.isEmpty
            && !host.username.trimmed.isEmpty
            && (1...65535).contains(host.port)
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Paste an OpenSSH or PEM private key")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                            TextEditor(text: $secret)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 120)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        SecureField("Key passphrase (if any)", text: $passphrase)
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
            if !secret.isEmpty {
                try KeyStore.shared.set(secret,
                                        for: h.id,
                                        kind: h.auth == .password ? .password : .privateKey)
            }
            if !passphrase.isEmpty {
                try KeyStore.shared.set(passphrase, for: h.id, kind: .passphrase)
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
