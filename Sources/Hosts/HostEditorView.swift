import SwiftUI

/// Add or edit a host.
///
/// Secrets are written straight to the Keychain on save and are never held in
/// the `Host` record, so a host that syncs or gets exported later carries no
/// credentials with it.
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let store: HostStore
    let groups: HostGroupStore
    /// nil = creating a new host.
    var existing: Host?

    @State private var host: Host
    @State private var secret: String = ""
    @State private var passphrase: String = ""
    @State private var error: String?
    @State private var library = KeyLibrary.shared
    @State private var managingKeys = false
    @State private var newGroup = ""

    init(store: HostStore, groups: HostGroupStore, existing: Host? = nil) {
        self.store = store
        self.groups = groups
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

    /// Every other saved host, since any of them can be a bastion. The host
    /// being edited is excluded: a machine cannot be reached through itself.
    private var jumpCandidates: [Host] {
        store.hosts
            .filter { $0.id != host.id }
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    /// A `ProxyJump` carried in from a config that names nothing saved. The
    /// picker cannot show it, so the value is kept and the footer explains
    /// it rather than the edit silently discarding it.
    private var unresolved: Bool {
        host.proxyJump != nil && store.jumpHost(for: host) == nil
    }

    private var selectedKeyNeedsPassphrase: Bool {
        guard let id = host.keyID else { return false }
        return library.key(withID: id)?.isEncrypted ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Name is what you'll see in the list. Leave it blank to use the hostname.")
                }

                Section {
                    Picker("Through", selection: $host.proxyJump) {
                        Text("Connect directly").tag(String?.none)
                        ForEach(jumpCandidates) { candidate in
                            Text(candidate.alias).tag(String?.some(candidate.alias))
                        }
                    }
                } header: {
                    Text("Jump host")
                } footer: {
                    // An imported ProxyJump can name a machine that was never
                    // saved, and the picker cannot offer what does not exist.
                    // Saying so here beats a connection that fails later with
                    // the reason three screens away.
                    if let jump = host.proxyJump, unresolved {
                        Text("\"\(jump)\" isn't a saved host yet. Add it as a host of its own, "
                             + "with the key it needs, or this one won't connect.")
                            .foregroundStyle(Theme.Status.danger)
                    } else {
                        Text("For a machine you can only reach through a bastion. "
                             + "The jump host is connected to first, with its own key.")
                    }
                }

                Section("Group") {
                    Picker("Group", selection: $host.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(groups.ordered) { group in
                            Label {
                                Text(group.name)
                            } icon: {
                                Circle().fill(group.color).frame(width: 8, height: 8)
                            }
                            .tag(UUID?.some(group.id))
                        }
                    }
                    HStack {
                        TextField("New group", text: $newGroup)
                            .textInputAutocapitalization(.words)
                        Button("Add") {
                            let name = newGroup.trimmed
                            guard !name.isEmpty else { return }
                            host.groupID = groups.create(name: name).id
                            newGroup = ""
                            Haptics.shared.fire(.success)
                        }
                        .disabled(newGroup.trimmed.isEmpty)
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
                    trustedKeySection
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


extension HostEditorView {
    /// The key this host is pinned to, and the only way to unpin it.
    ///
    /// Deliberately *here* rather than on the mismatch wall. When a key
    /// changes, a rebuilt server and an attacker look identical from the
    /// phone, so the wall refuses and says so — and forgetting the old key is
    /// something you come and do on purpose, having checked the new
    /// fingerprint some other way. A "continue anyway" button in the moment
    /// of the warning is how this protection gets clicked through.
    @ViewBuilder
    var trustedKeySection: some View {
        if let known = KnownHostsStore.shared.entry(for: host.address) {
            Section("Trusted host key") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(known.fingerprint)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(known.keyType) \u{00b7} trusted \(known.firstSeen.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 2)

                Button("Forget this key", role: .destructive) {
                    KnownHostsStore.shared.forget(host.address)
                    Haptics.shared.fire(.warning)
                }
            }
        }
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
