import SwiftUI

/// The app's home screen: your hosts, grouped.
///
/// Conterm on macOS has no host database at all — it derives a list from
/// `~/.ssh/config` and scraped shell history, because `/usr/bin/ssh` did the
/// rest. Neither exists here, so this list is backed by real records. Until
/// the store lands, it shows whatever config the user has imported.
struct HostListView: View {
    let app: Ghostty.App

    @State private var hosts: [SSHConfigHost] = []
    @State private var query = ""
    @State private var session: TerminalSession?
    @State private var importing = false

    private var filtered: [SSHConfigHost] {
        guard !query.isEmpty else { return hosts }
        let q = query.lowercased()
        return hosts.filter {
            $0.alias.lowercased().contains(q)
                || ($0.hostname?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    EmptyHostsView(importing: $importing)
                } else {
                    list
                }
            }
            .background(Theme.backdropDark.ignoresSafeArea())
            .navigationTitle("Hosts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .tint(Theme.accentOnDark)
                }
            }
            .searchable(text: $query, prompt: "Search hosts")
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { result in
                importConfig(result)
            }
            .navigationDestination(item: $session) { session in
                TerminalScreen(session: session)
            }
        }
        .tint(Theme.accentOnDark)
    }

    private var list: some View {
        List(filtered) { host in
            Button {
                open(host)
            } label: {
                HostRow(host: host)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.stroke)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func open(_ host: SSHConfigHost) {
        session = TerminalSession(host: host, app: app)
    }

    private func importConfig(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        // A file chosen through the picker lives outside our container, so
        // access has to be claimed and released explicitly.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        hosts = SSHConfig.parse(fileAt: url).hosts
    }
}

/// One host. A status gem, the alias, and enough underneath to tell two
/// similar aliases apart — which is the whole job of this row.
private struct HostRow: View {
    let host: SSHConfigHost

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Theme.Status.neutral)
                .frame(width: 6, height: 6)
                .shadow(color: Theme.Status.neutral.opacity(0.6), radius: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.alias)
                    .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: Theme.ui(11), weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// `user@host:port`, with the parts that are already the default left out
    /// — a list where every row says ":22" has spent its width on nothing.
    private var subtitle: String? {
        var parts: [String] = []
        if let user = host.user { parts.append(user + "@") }
        if let hostname = host.hostname, hostname != host.alias {
            parts.append(hostname)
        } else if host.user != nil {
            parts.append(host.alias)
        }
        if let port = host.port, port != 22 { parts.append(":\(port)") }
        let joined = parts.joined()
        return joined.isEmpty ? nil : joined
    }
}

private struct EmptyHostsView: View {
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("No hosts yet")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Import an ssh config to get started. Includes are followed, and Port, User, IdentityFile and ProxyJump all come across.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("Import ssh config") { importing = true }
                .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accentOnDark)
                .padding(.horizontal, 16)
                .frame(height: Theme.hitTarget)
                .glassPill(tone: .dark)
                .padding(.top, 4)
        }
    }
}
