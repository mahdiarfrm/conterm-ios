import SwiftUI

/// The snippet list for a session: tap to run.
///
/// Deliberately not a management screen with a run button hidden in it. The
/// whole point is one tap between wanting a command and having typed it, so
/// the row *is* the button and editing lives behind a long press.
struct SnippetsView: View {
    let host: Host?
    let onRun: (Snippet) -> Void

    @State private var store = SnippetStore.shared
    @State private var editing: Snippet?
    @State private var creating = false
    @Environment(\.dismiss) private var dismiss

    private var visible: [Snippet] { store.snippets(for: host) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(visible) { snippet in
                        Button {
                            store.noteUsed(snippet)
                            Haptics.shared.fire(.light)
                            onRun(snippet)
                            dismiss()
                        } label: {
                            row(snippet)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.stroke)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = snippet }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(snippet)
                            }
                        }
                    }
                } footer: {
                    if let host {
                        Text("Showing snippets for \(host.alias) and the ones you keep "
                           + "everywhere.")
                            .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { snippet in
                SnippetEditor(host: host, existing: snippet)
            }
            .sheet(isPresented: $creating) {
                SnippetEditor(host: host, existing: nil)
            }
        }
        .tint(Theme.accentOnDark)
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snippet.title)
                        .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    if snippet.hostID != nil {
                        Text("this host")
                            .font(.system(size: Theme.ui(9), weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.07)))
                    }
                    if !snippet.submits {
                        Image(systemName: "pencil")
                            .font(.system(size: Theme.ui(9), weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(snippet.command)
                    .font(.system(size: Theme.ui(11.5), weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: Theme.ui(17)))
                .foregroundStyle(Theme.sshAccent)
        }
        .padding(.vertical, 5)
    }
}

/// Add or change one.
struct SnippetEditor: View {
    let host: Host?
    var existing: Snippet?

    @State private var title = ""
    @State private var command = ""
    @State private var scopedToHost = false
    @State private var submits = true
    @State private var store = SnippetStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $title)
                    TextField("Command", text: $command, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.system(size: Theme.ui(13), weight: .medium, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    if host != nil {
                        Toggle("Only on \(host?.alias ?? "")", isOn: $scopedToHost)
                    }
                    Toggle("Run immediately", isOn: $submits)
                } footer: {
                    Text(submits
                         ? "Runs as soon as you tap it."
                         : "Types it and waits, so you can finish the line before it runs.")
                }
                if let existing {
                    Section {
                        Button("Delete", role: .destructive) {
                            store.delete(existing)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle(existing == nil ? "New Snippet" : "Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                                  || command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let existing else {
                    scopedToHost = host != nil
                    return
                }
                title = existing.title
                command = existing.command
                scopedToHost = existing.hostID != nil
                submits = existing.submits
            }
        }
        .tint(Theme.accentOnDark)
    }

    private func save() {
        var snippet = existing ?? Snippet(title: "", command: "")
        snippet.title = title.trimmingCharacters(in: .whitespaces)
        snippet.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.hostID = scopedToHost ? host?.id : nil
        snippet.submits = submits
        if existing == nil { store.add(snippet) } else { store.update(snippet) }
        dismiss()
    }
}
