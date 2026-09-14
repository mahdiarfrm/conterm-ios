import SwiftUI
import UniformTypeIdentifiers

/// Your imported keys.
///
/// Import once, use on any host. A private key file has no extension and no
/// registered type, so the picker has to accept `.data` and `.item` — asking
/// for anything narrower makes `id_rsa` unselectable in Files, greyed out
/// with no explanation, which is exactly the wall you hit.
struct KeyLibraryView: View {
    /// On a tab rather than in a sheet: a cream card with its own title row,
    /// and no Done button because there is nothing to dismiss.
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @State private var library = KeyLibrary.shared
    @State private var importing = false
    @State private var pasting = false
    @State private var error: String?
    @State private var renaming: SSHKey?
    @State private var newName = ""

    var body: some View {
        Group {
            if embedded {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CardHeader(title: "Keys", count: library.keys.count)
                        addMenu
                            .padding(.trailing, 20)
                    }
                    core
                }
                .creamCard()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .contermReadableColumn(740)
            } else {
                NavigationStack {
                    core
                        .creamSheet()
                        .navigationTitle("Keys")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Menu {
                                    addActions
                                } label: { Image(systemName: "plus") }
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .tint(Theme.Brand.ink)
    }

    @ViewBuilder
    private var addActions: some View {
        Button { importing = true } label: {
            Label("Import from Files", systemImage: "folder")
        }
        Button { pasting = true } label: {
            Label("Paste key text", systemImage: "doc.on.clipboard")
        }
    }

    private var addMenu: some View {
        Menu {
            addActions
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Theme.ui(13), weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.ui(34), height: Theme.ui(34))
                .background(Circle().fill(Theme.accentSoft))
        }
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 8 }
    }

    private var core: some View {
        Group {
            if library.keys.isEmpty { empty } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fileImporter(isPresented: $importing,
                          // .data and .item both matter: an extensionless
                          // id_rsa resolves to public.data, and some
                          // providers hand back only public.item.
                          allowedContentTypes: [.data, .item, .text],
                          allowsMultipleSelection: false) { importFile($0) }
            .sheet(isPresented: $pasting) { PasteKeySheet(onAdd: add) }
            .alert("Rename key", isPresented: .constant(renaming != nil)) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let key = renaming { library.rename(key, to: newName) }
                    renaming = nil
                }
            }
            .alert("Couldn't import that key",
                   isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "key")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .rollUp(delay: 0.05)
            Text("No keys yet")
                .font(Theme.font(19, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .rollUp(delay: 0.11)
            Text("Import the private key — id_rsa or id_ed25519, the one **without** the .pub extension. Put it in iCloud Drive or AirDrop it to yourself first.")
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .rollUp(delay: 0.17)
            Button("Import from Files") { importing = true }
                .font(Theme.font(Theme.ui(15), .semibold))
                .filledPill()
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
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                            .font(Theme.font(Theme.ui(14), .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(key.format.label + (key.isEncrypted ? " · passphrase" : ""))
                            .font(Theme.font(Theme.ui(11), .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.stroke)
                .revealCascade(index)
                .swipeActions {
                    Button("Delete") { library.delete(key) }
                        .tint(Theme.Action.destructive)
                    Button("Rename") {
                        newName = key.name
                        renaming = key
                    }
                    .tint(Theme.Action.neutral)
                }
                .contextMenu {
                    Button {
                        newName = key.name
                        renaming = key
                    } label: { Label("Rename", systemImage: "pencil") }
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
            .creamSheet()
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
        .tint(Theme.Brand.ink)
    }
}
