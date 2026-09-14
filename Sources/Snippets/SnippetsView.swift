import SwiftUI

/// The snippet list for a session: tap to run.
///
/// Deliberately not a management screen with a run button hidden in it. The
/// whole point is one tap between wanting a command and having typed it, so
/// the row *is* the button and editing lives behind a long press.
struct SnippetsView: View {
    let host: Host?
    /// On a tab rather than in a sheet: a cream card with its own title row,
    /// and nothing to dismiss when a snippet is picked.
    var embedded = false
    let onRun: (Snippet) -> Void

    @State private var store = SnippetStore.shared
    @State private var editing: Snippet?
    @State private var creating = false
    @Environment(\.dismiss) private var dismiss

    private var visible: [Snippet] { store.snippets(for: host) }

    var body: some View {
        Group {
            if embedded {
                VStack(spacing: 0) {
                    CardHeader(title: "Snippets", count: visible.count, symbol: "plus") {
                        creating = true
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
                }
            }
        }
        .tint(Theme.Brand.ink)
    }

    private var core: some View {
            List {
                Section {
                    ForEach(visible) { snippet in
                        Button {
                            store.noteUsed(snippet)
                            Haptics.shared.fire(.light)
                            onRun(snippet)
                            if !embedded { dismiss() }
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
                            .font(Theme.font(Theme.ui(11), .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .sheet(item: $editing) { snippet in
                SnippetEditor(host: host, existing: snippet)
            }
            .sheet(isPresented: $creating) {
                SnippetEditor(host: host, existing: nil)
            }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snippet.title)
                        .font(Theme.font(Theme.ui(15), .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if snippet.hostID != nil {
                        Text("this host")
                            .font(Theme.font(Theme.ui(9), .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentSoft))
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
            .creamSheet()
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
        .tint(Theme.Brand.ink)
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
