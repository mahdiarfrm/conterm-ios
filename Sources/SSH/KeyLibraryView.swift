import SwiftUI
import UniformTypeIdentifiers

/// Your imported keys.
///
/// Import once, use on any host. A private key file has no extension and no
/// registered type, so the picker has to accept `.data` and `.item` — asking
/// for anything narrower makes `id_rsa` unselectable in Files, greyed out
/// with no explanation, which is exactly the wall you hit.
struct KeyLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = KeyLibrary.shared
    @State private var importing = false
    @State private var pasting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.keys.isEmpty { empty } else { list }
            }
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle("Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button { importing = true } label: {
                            Label("Import from Files", systemImage: "folder")
                        }
                        Button { pasting = true } label: {
                            Label("Paste key text", systemImage: "doc.on.clipboard")
                        }
                    } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing,
                          // .data and .item both matter: an extensionless
                          // id_rsa resolves to public.data, and some
                          // providers hand back only public.item.
                          allowedContentTypes: [.data, .item, .text],
                          allowsMultipleSelection: false) { importFile($0) }
            .sheet(isPresented: $pasting) { PasteKeySheet(onAdd: add) }
            .alert("Couldn't import that key",
                   isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .tint(Theme.accentOnDark)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "key")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .rollUp(delay: 0.05)
            Text("No keys yet")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .rollUp(delay: 0.11)
            Text("Import the private key — id_rsa or id_ed25519, the one **without** the .pub extension. Put it in iCloud Drive or AirDrop it to yourself first.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .rollUp(delay: 0.17)
            Button("Import from Files") { importing = true }
                .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.appBackground)
                .padding(.horizontal, 22)
                .frame(height: Theme.hitTarget)
                .background(Capsule().fill(Theme.accentOnDark))
                .buttonStyle(PressablePill())
                .rollUp(delay: 0.23)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(Array(library.keys.enumerated()), id: \.element.id) { index, key in
                HStack(spacing: 11) {
                    Image(systemName: key.isEncrypted ? "lock.fill" : "key.fill")
                        .font(.system(size: Theme.ui(13), weight: .medium))
                        .foregroundStyle(Theme.sshAccent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                            .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text(key.format.label + (key.isEncrypted ? " · passphrase" : ""))
                            .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.stroke)
                .revealCascade(index)
                .swipeActions {
                    Button("Delete", role: .destructive) { library.delete(key) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            error = "Couldn't read that file."
            return
        }
        add(String(decoding: data, as: UTF8.self), name: url.lastPathComponent)
    }

    private func add(_ text: String, name: String) {
        do {
            try library.add(text: text, name: name)
            SoundEffects.shared.tap(.paletteConfirm, haptic: .success)
        } catch {
            self.error = error.localizedDescription
            SoundEffects.shared.play(.error)
            Haptics.shared.fire(.failure)
        }
    }
}

/// For when the key is on the clipboard rather than in Files.
private struct PasteKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String, String) -> Void

    @State private var text = ""
    @State private var name = "Pasted key"

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("id_rsa", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Private key") {
                    TextEditor(text: $text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle("Paste Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(text, name.trimmed.isEmpty ? "Pasted key" : name.trimmed)
                        dismiss()
                    }
                    .disabled(text.trimmed.isEmpty)
                }
            }
        }
        .tint(Theme.accentOnDark)
    }
}
