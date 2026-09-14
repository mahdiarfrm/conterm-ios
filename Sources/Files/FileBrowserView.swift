import SwiftUI
import UniformTypeIdentifiers

/// A directory on a host, pushed. Folders push another of these; files
/// open into a preview. Uploads come in through the Files picker, and
/// anything here can be renamed, deleted or shared out.
struct FileBrowserView: View {
    let host: Host
    /// nil for the home directory, resolved by the host.
    var path: String? = nil

    @State private var model: FileBrowserModel?
    @State private var prefs = Preferences.shared
    @State private var preview: RemoteEntry?
    @State private var importing = false
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var deleting: RemoteEntry?
    @State private var sharing: URL?
    @State private var sort: FileBrowserModel.Sort = .name

    /// A name being asked for.
    enum Naming: Identifiable {
        case folder, file, rename(RemoteEntry)
        var id: String {
            switch self {
            case .folder: return "folder"
            case .file: return "file"
            case .rename(let entry): return "rename-\(entry.path)"
            }
        }
        var title: String {
            switch self {
            case .folder: return "New folder"
            case .file: return "New file"
            case .rename: return "Rename"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let model {
                    if let error = model.error {
                        errorPanel(error)
                    } else if model.loading && model.entries.isEmpty {
                        loadingPanel
                    } else {
                        listing(model)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
            .contermReadableColumn()
        }
        .softTopEdge()
        .brandGround()
        .navigationTitle(model?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await model?.load() }
        .overlay(alignment: .bottom) { busy }
        .task { await start() }
        .navigationDestination(item: $preview) { entry in
            FilePreviewView(host: host, entry: entry, transport: model?.transport)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            Task { await model?.upload(urls) }
        }
        .alert(naming?.title ?? "", isPresented: Binding(
            get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(namingVerb) { commitName() }
        }
        .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(deleting?.isDirectory == true ? "Delete folder and everything in it"
                   : "Delete", role: .destructive) {
                if let entry = deleting { Task { await model?.remove(entry) } }
                deleting = nil
            }
        } message: {
            Text("This removes it from \(host.alias). There is no undo.")
        }
        .alert("Files", isPresented: Binding(
            get: { model?.notice != nil }, set: { if !$0 { model?.notice = nil } })) {
            Button("OK") { model?.notice = nil }
        } message: {
            Text(model?.notice ?? "")
        }
        .sheet(item: $sharing) { url in
            ShareSheet(items: [url]).presentationDetents([.medium, .large])
        }
    }

    private func start() async {
        guard model == nil else { return }
        let made = FileBrowserModel(host: host, path: path,
                                    transport: FileTransports.transport(for: host))
        model = made
        await made.load()
        // The tour opens the first note it finds, so the preview is on
        // film too.
        if ProcessInfo.processInfo.environment["CONTERM_TOUR"] != nil, path == nil {
            try? await Task.sleep(for: .seconds(3.5))
            preview = made.entries.first { $0.fileExtension == "md" }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelLabel("Files · \(host.alias)", symbol: "folder.fill")
            Text(model?.name ?? host.alias)
                .font(Theme.font(Theme.ui(30), .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .morph(on: model?.name ?? "", alignment: .leading)
            Text(model?.path ?? "…")
                .font(.system(size: Theme.ui(12.5), weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.head)
                .morph(on: model?.path ?? "", alignment: .leading)
            if let model, model.error == nil, !(model.loading && model.entries.isEmpty) {
                let folders = model.entries.filter(\.isDirectory).count
                let files = model.entries.count - folders
                let bytes = model.entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
                FlowLayout(spacing: 6) {
                    Bubble("\(folders)", symbol: "folder", detail: folders == 1 ? "folder" : "folders")
                        .popIn(0, base: 0.1)
                    Bubble("\(files)", symbol: "doc", detail: files == 1 ? "file" : "files")
                        .popIn(1, base: 0.1)
                    if bytes > 0 {
                        Bubble(formatBytes(Double(bytes)), symbol: "internaldrive")
                            .popIn(2, base: 0.1)
                    }
                }
                .transition(.morph)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .animation(Theme.Spring.morph, value: model?.entries.count)
        .rollUp()
    }

    // MARK: - The listing

    private func listing(_ model: FileBrowserModel) -> some View {
        let shown = model.visible(hidden: prefs.filesShowHidden, sort: sort)
        return Panel(bed: .cream, padding: 6) {
            if shown.isEmpty {
                Text(model.entries.isEmpty ? "Nothing here."
                     : "Only hidden things here. Show them from the menu.")
                    .font(Theme.font(Theme.ui(14), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        row(entry)
                            .popIn(min(index, 14), base: 0.03)
                        if index < shown.count - 1 {
                            Rectangle().fill(Theme.stroke).frame(height: 0.5)
                                .padding(.leading, 62)
                        }
                    }
                }
            }
        }
        .arrive(1)
    }

    @ViewBuilder
    private func row(_ entry: RemoteEntry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink(value: RemoteDirectory(host: host, path: entry.path)) {
                    EntryRow(entry: entry)
                }
            } else {
                Button {
                    Haptics.shared.fire(.light)
                    preview = entry
                } label: {
                    EntryRow(entry: entry)
                }
            }
        }
        .buttonStyle(PressableRow())
        .contextMenu {
            if !entry.isDirectory {
                Button("Share", systemImage: "square.and.arrow.up") {
                    Task { if let url = await model?.download(entry) { sharing = url } }
                }
            }
            Button("Rename", systemImage: "pencil") {
                nameText = entry.name
                naming = .rename(entry)
            }
            Button("Copy path", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = entry.path
                Haptics.shared.fire(.selection)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
        }
    }

    private var loadingPanel: some View {
        Panel(bed: .glass) {
            HStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                Text("Reading \(model?.path ?? "the folder")…")
                    .font(Theme.font(Theme.ui(14), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .arrive(1)
    }

    private func errorPanel(_ text: String) -> some View {
        Panel("Couldn't read this folder", symbol: "exclamationmark.triangle.fill", bed: .amber) {
            VStack(alignment: .leading, spacing: 14) {
                Text(text)
                    .font(Theme.font(Theme.ui(15), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Button {
                    Task { await model?.load() }
                } label: {
                    Bubble("Try again", symbol: "arrow.clockwise", lit: true)
                }
                .buttonStyle(PressablePill(scale: 0.94))
            }
        }
        .arrive(1)
    }

    /// What is in flight, at the foot.
    @ViewBuilder
    private var busy: some View {
        if let busy = model?.busy {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.textPrimary).controlSize(.small)
                Text(busy)
                    .font(Theme.font(Theme.ui(13), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassPill(selected: true)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(Theme.Spring.snappy, value: busy)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Upload from Files", systemImage: "square.and.arrow.down") {
                    importing = true
                }
                Button("New folder", systemImage: "folder.badge.plus") {
                    nameText = ""
                    naming = .folder
                }
                Button("New file", systemImage: "doc.badge.plus") {
                    nameText = ""
                    naming = .file
                }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(model?.path == nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle("Show hidden", systemImage: "eye", isOn: $prefs.filesShowHidden)
                Picker("Sort by", selection: $sort) {
                    Label("Name", systemImage: "textformat").tag(FileBrowserModel.Sort.name)
                    Label("Newest first", systemImage: "clock").tag(FileBrowserModel.Sort.modified)
                    Label("Largest first", systemImage: "arrow.down.right.and.arrow.up.left")
                        .tag(FileBrowserModel.Sort.size)
                }
                Divider()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model?.load() }
                }
                Button("Copy path", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = model?.path
                }
                .disabled(model?.path == nil)
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private var namingVerb: String {
        if case .rename = naming { return "Rename" }
        return "Create"
    }

    private func commitName() {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !name.isEmpty, !name.contains("/") else { naming = nil; return }
        let which = naming
        naming = nil
        Task {
            switch which {
            case .folder: await model.makeDirectory(name)
            case .file: await model.makeFile(name)
            case .rename(let entry): await model.rename(entry, to: name)
            case nil: break
            }
        }
    }
}

/// A folder to push: the host and the path in it. Value-typed so the
/// stack can hold any depth of them.
struct RemoteDirectory: Hashable {
    let host: Host
    let path: String
}

// MARK: - One row

private struct EntryRow: View {
    let entry: RemoteEntry

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: entry.flavour.symbol)
                        .font(.system(size: Theme.ui(15), weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(Theme.font(Theme.ui(15), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.font(Theme.ui(11.5), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.ui(12), weight: .bold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            } else {
                Text(formatBytes(Double(entry.size)))
                    .font(Theme.font(Theme.ui(12), .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        switch entry.kind {
        case .directory: parts.append("Folder")
        case .link: parts.append(entry.linkTarget.map { "→ \($0)" } ?? "Link")
        case .file, .other: break
        }
        if let modified = entry.modified { parts.append(whenLabel(modified)) }
        parts.append(entry.permissions)
        return parts.joined(separator: "  ·  ")
    }
}

/// A date as a short word: the time today, the day this year, the month
/// and year before that.
func whenLabel(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.month(.abbreviated).year())
}

/// The system share sheet. Saving to Files, AirDrop, and every app that
/// takes a file are all in there.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - The model

/// One directory's state: what is in it, what is happening to it.
@MainActor
@Observable
final class FileBrowserModel {
    let host: Host
    let transport: (any RemoteFileTransport)?
    private(set) var path: String?
    private(set) var entries: [RemoteEntry] = []
    private(set) var loading = false
    private(set) var error: String?
    /// What is in flight, as a sentence.
    private(set) var busy: String?
    var notice: String?

    enum Sort: Hashable { case name, modified, size }

    /// The biggest upload that goes through one exec channel's buffer
    /// without making the phone sweat.
    static let uploadLimit = 32 * 1024 * 1024

    init(host: Host, path: String?, transport: (any RemoteFileTransport)?) {
        self.host = host
        self.path = path
        self.transport = transport
    }

    var name: String {
        guard let path else { return host.alias }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    func load() async {
        guard let transport else {
            error = RemoteFileError.noCredentials.localizedDescription
            return
        }
        loading = true
        defer { loading = false }
        do {
            let target: String
            if let path { target = path } else { target = try await transport.home() }
            let listing = try await transport.list(target)
            path = listing.path
            entries = listing.entries
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Folders first, then by the chosen order.
    func visible(hidden: Bool, sort: Sort) -> [RemoteEntry] {
        let shown = hidden ? entries : entries.filter { !$0.isHidden }
        return shown.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sort {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .modified:
                return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            case .size:
                return a.size > b.size
            }
        }
    }

    func child(_ name: String) -> String {
        guard let path else { return name }
        return path == "/" ? "/" + name : path + "/" + name
    }

    func makeDirectory(_ name: String) async {
        await perform("Making \(name)…") { try await $0.makeDirectory(self.child(name)) }
    }

    func makeFile(_ name: String) async {
        await perform("Making \(name)…") { try await $0.touch(self.child(name)) }
    }

    func rename(_ entry: RemoteEntry, to name: String) async {
        await perform("Renaming \(entry.name)…") { try await $0.move(entry.path, to: self.child(name)) }
    }

    func remove(_ entry: RemoteEntry) async {
        Haptics.shared.fire(.warning)
        await perform("Deleting \(entry.name)…") { try await $0.remove(entry) }
    }

    /// Files from the picker, up to the host. Each is read on the phone
    /// while its security scope is open, then sent whole.
    func upload(_ urls: [URL]) async {
        for url in urls {
            let name = url.lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                notice = "Couldn't read \(name) on this phone."
                continue
            }
            guard data.count <= Self.uploadLimit else {
                notice = RemoteFileError.tooLarge(Int64(data.count)).localizedDescription
                continue
            }
            await perform("Uploading \(name) · \(formatBytes(Double(data.count)))") {
                try await $0.write(self.child(name), data: data)
            }
        }
    }

    /// A file down to the phone, into a temporary file the share sheet
    /// can hand on.
    func download(_ entry: RemoteEntry) async -> URL? {
        guard let transport else { return nil }
        guard entry.size <= FilePreviewView.shareLimit else {
            notice = RemoteFileError.tooLarge(entry.size).localizedDescription
            return nil
        }
        busy = "Fetching \(entry.name) · \(formatBytes(Double(entry.size)))"
        defer { busy = nil }
        do {
            let data = try await transport.read(entry.path, limit: FilePreviewView.shareLimit)
            return try FilePreviewView.stash(data, named: entry.name)
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    private func perform(_ what: String,
                         _ work: (any RemoteFileTransport) async throws -> Void) async {
        guard let transport else { return }
        busy = what
        defer { busy = nil }
        do {
            try await work(transport)
            Haptics.shared.fire(.light)
            await load()
        } catch {
            Haptics.shared.fire(.warning)
            notice = error.localizedDescription
        }
    }
}
