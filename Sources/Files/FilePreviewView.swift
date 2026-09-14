import SwiftUI

/// One file, opened. The name enormous with its facts beneath, then the
/// file itself on a cream card: text you can edit and save back, a picture
/// drawn, anything else described. The share button hands the bytes to
/// the share sheet, which is how they get to the Files app, AirDrop, or
/// anywhere else.
struct FilePreviewView: View {
    let host: Host
    let entry: RemoteEntry
    let transport: (any RemoteFileTransport)?

    @State private var data: Data?
    @State private var text = ""
    @State private var original = ""
    @State private var image: UIImage?
    @State private var loading = true
    @State private var error: String?
    @State private var saving = false
    @State private var savedAt: Date?
    @State private var shareURL: URL?
    /// The share sheet is up. A `ShareLink` on a file URL has the system
    /// build a link preview the moment it is drawn, which on a big file
    /// holds the main thread for seconds; a plain button that presents
    /// the sheet costs nothing until it is tapped.
    @State private var sharing = false
    @State private var truncated = false
    /// The editor is up. Reading is a `Text`; a `TextEditor` sized to its
    /// content inside a scroll view is a layout loop waiting to happen.
    @State private var editing = false
    @FocusState private var focused: Bool

    /// Text opens in the editor up to here; past it the file is shown
    /// as a fact and shared whole.
    static let editLimit = 512 * 1024
    /// The most this fetches for a preview or a share.
    static let shareLimit = 64 * 1024 * 1024

    private var edited: Bool { text != original }
    private var isText: Bool { image == nil && data != nil && !textTooBig && textLooksLikeText }
    private var textTooBig: Bool { (data?.count ?? 0) > Self.editLimit }
    @State private var textLooksLikeText = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelLabel("File · \(host.alias)", symbol: entry.flavour.symbol)
                    .padding(.horizontal, 4)
                    .rollUp()

                Text(entry.name)
                    .font(Theme.font(Theme.ui(34), .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 10)
                    .padding(.horizontal, 2)
                    .rollUp(delay: 0.05)

                Text(entry.path)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                    .rollUp(delay: 0.1)

                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                    .padding(.top, 20)
                HStack(alignment: .top, spacing: 16) {
                    DetailFact(value: formatBytes(Double(entry.size)), label: "Size")
                    DetailFact(value: entry.modified.map { whenLabel($0) } ?? "—", label: "Changed")
                    DetailFact(value: entry.permissions, label: entry.owner)
                }
                .padding(.top, 16)
                .padding(.horizontal, 4)
                .rollUp(delay: 0.14)

                card
                    .padding(.top, 24)
                    .arrive(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .contermReadableColumn()
        }
        .softTopEdge()
        .brandGround()
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if editing {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView().controlSize(.small) }
                        else { Text(edited ? "Save" : "Done").font(Theme.font(Theme.ui(15), .bold)) }
                    }
                    .disabled(saving)
                } else if isText, !truncated {
                    Button {
                        Haptics.shared.fire(.light)
                        editing = true
                        focused = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if shareURL != nil, !editing {
                    Button {
                        Haptics.shared.fire(.light)
                        sharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Hide keyboard") { focused = false }
                    .font(Theme.font(Theme.ui(15), .bold))
            }
        }
        .task { await load() }
        .sheet(isPresented: $sharing) {
            if let shareURL {
                ShareSheet(items: [shareURL]).presentationDetents([.medium, .large])
            }
        }
        .animation(Theme.Spring.snappy, value: edited)
        .animation(Theme.Spring.snappy, value: editing)
        .animation(Theme.Spring.morph, value: loading)
    }

    // MARK: - The card

    private var card: some View {
        Panel(bed: .cream, padding: 16) {
            if loading {
                HStack(spacing: 12) {
                    ProgressView().tint(Theme.accent)
                    Text("Fetching \(formatBytes(Double(min(entry.size, Int64(Self.shareLimit)))))…")
                        .font(Theme.font(Theme.ui(14), .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error {
                fact("exclamationmark.triangle.fill", error)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomTrailing) {
                        Bubble("\(Int(image.size.width)) × \(Int(image.size.height))")
                            .padding(10)
                    }
            } else if isText {
                if editing { editor } else { reader }
            } else if textTooBig {
                fact("doc.text.magnifyingglass",
                     "Too long to edit here. Share it to open the whole file elsewhere.")
            } else {
                fact("doc.zipper",
                     "Not text. Share it to save it to Files or send it on.")
            }
        }
    }

    private var lineCount: Int {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    private var caption: some View {
        HStack(spacing: 8) {
            Text("\(lineCount) lines")
                .font(Theme.font(Theme.ui(11.5), .bold))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
            if truncated {
                Bubble("first \(formatBytes(Double(data?.count ?? 0))) only", symbol: "scissors")
            }
            Spacer(minLength: 0)
            if let savedAt, !edited {
                Bubble("Saved", symbol: "checkmark", lit: true)
                    .transition(.morph)
                    .id(savedAt)
            }
        }
    }

    /// The file, read. Tap the pencil to change it.
    private var reader: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption
            Text(text)
                .font(.system(size: Theme.ui(13), design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The file, open for changes. A fixed height, so the editor scrolls
    /// inside itself rather than asking the page to fit it.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption
            TextEditor(text: $text)
                .font(.system(size: Theme.ui(13), design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .frame(height: min(max(CGFloat(lineCount) * 19 + 40, 200), 460))
        }
    }

    private func fact(_ symbol: String, _ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: Theme.ui(18), weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(Theme.font(Theme.ui(14), .medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bytes in, bytes out

    private func load() async {
        guard let transport else {
            error = RemoteFileError.noCredentials.localizedDescription
            loading = false
            return
        }
        do {
            let bytes = try await transport.read(entry.path, limit: Self.shareLimit)
            data = bytes
            truncated = entry.size > Int64(bytes.count)
            if entry.flavour == .image, let picture = UIImage(data: bytes) {
                image = picture
            } else if bytes.count <= Self.editLimit, let string = String(data: bytes, encoding: .utf8),
                      !bytes.contains(0) {
                textLooksLikeText = true
                text = string
                original = string
            }
            shareURL = try? Self.stash(bytes, named: entry.name)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        guard let transport else { return }
        saving = true
        defer { saving = false }
        do {
            let bytes = Data(text.utf8)
            if edited {
                try await transport.write(entry.path, data: bytes)
                original = text
                data = bytes
                shareURL = try? Self.stash(bytes, named: entry.name)
                savedAt = Date()
                Haptics.shared.fire(.success)
            }
            focused = false
            editing = false
        } catch {
            Haptics.shared.fire(.warning)
            self.error = error.localizedDescription
        }
    }

    /// The bytes as a file the share sheet can take, under the name the
    /// host had for it.
    static func stash(_ data: Data, named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-files", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "file" : name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
