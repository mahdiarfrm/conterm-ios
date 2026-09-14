import SwiftUI
import os

/// One of the Mac's panes, on the phone: its screen as the Mac shows it,
/// a row of the keys a terminal needs, and a line to type into it.
///
/// Two ways to look at the pane. As a picture, the Mac captures the pane's
/// pixels, so colours, bold and the layout come through exactly and the
/// whole width fits the phone; pinch to zoom. As text, the Mac reads the
/// screen's characters, which wrap to the phone, scale with a font size
/// and can be selected and copied. Keys and text go back through the
/// inbox as key events, so a TUI such as Claude Code sees a real Return
/// and a real Escape.
struct MacPaneView: View {
    let link: ContermRemoteLink
    let pane: ContermState.Pane

    @State private var prefs = Preferences.shared
    @State private var screen: String?
    @State private var picture: UIImage?
    @State private var connected = false
    @State private var channel: SSHChannelID?
    @State private var input = ""
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var generation = 0
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    private static let keys: [(label: String, symbol: String?, name: String)] = [
        ("esc", nil, "escape"),
        ("tab", nil, "tab"),
        ("^C", nil, "ctrl-c"),
        ("^D", nil, "ctrl-d"),
        ("^L", nil, "ctrl-l"),
        ("", "arrow.left", "left"),
        ("", "arrow.up", "up"),
        ("", "arrow.down", "down"),
        ("", "arrow.right", "right"),
        ("", "delete.left", "backspace"),
        ("", "return", "return"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            display
            if pane.agentPhase == "attention" {
                attention
            }
            keyRow
            inputRow
        }
        .background(Theme.paneTile.ignoresSafeArea(.all, edges: .all))
        .navigationTitle(pane.title ?? pane.remoteHost ?? pane.dirLabel ?? "Pane")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paneTitleBar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show as", selection: $prefs.panePicture) {
                        Label("Picture", systemImage: "photo").tag(true)
                        Label("Text", systemImage: "text.alignleft").tag(false)
                    }
                    if !prefs.panePicture {
                        Toggle("Wrap lines", systemImage: "text.word.spacing", isOn: $prefs.paneWrap)
                        Button("Bigger text", systemImage: "textformat.size.larger") {
                            prefs.paneFontSize = min(prefs.paneFontSize + 1, 18)
                        }
                        Button("Smaller text", systemImage: "textformat.size.smaller") {
                            prefs.paneFontSize = max(prefs.paneFontSize - 1, 7)
                        }
                    }
                    Divider()
                    Button("Bring to front on the Mac", systemImage: "macwindow.on.rectangle") {
                        Task { await link.send(.init(action: .focusPane, paneID: pane.id)) }
                    }
                    Button("Clear screen (^L)", systemImage: "eraser") {
                        Task { await link.key("ctrl-l", into: pane.id) }
                    }
                    Button("Interrupt (^C)", systemImage: "stop.circle", role: .destructive) {
                        Task { await link.key("ctrl-c", into: pane.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    typing = false
                } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                        .font(Theme.font(Theme.ui(14), .bold))
                }
            }
        }
        .task(id: generation) { await run() }
        .onChange(of: prefs.panePicture) {
            // A different file on the Mac: attach again asking for it, and
            // stream that one instead.
            let old = channel
            channel = nil
            Task { if let old { await link.closeScreen(old) } }
            generation += 1
        }
        .onDisappear {
            let id = channel
            Task {
                await link.detach(pane.id)
                if let id { await link.closeScreen(id) }
            }
        }
    }

    // MARK: - The screen

    private var display: some View {
        GeometryReader { geo in
            ScrollView(prefs.panePicture || !prefs.paneWrap ? [.vertical, .horizontal] : [.vertical]) {
                Group {
                    if prefs.panePicture, let picture {
                        Image(uiImage: picture)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: max(geo.size.width * zoom * pinch, 1))
                            .gesture(MagnifyGesture()
                                .onChanged { pinch = $0.magnification }
                                .onEnded { _ in
                                    zoom = min(max(zoom * pinch, 1), 4)
                                    pinch = 1
                                })
                    } else if let screen {
                        Text(screen)
                            .font(.system(size: prefs.paneFontSize, design: .monospaced))
                            .foregroundStyle(Color(white: 0.92))
                            .fixedSize(horizontal: !prefs.paneWrap, vertical: false)
                            .textSelection(.enabled)
                            .padding(12)
                    } else {
                        Text(connected ? (prefs.panePicture
                                          ? "Waiting for the Mac to draw this pane…"
                                          : "Waiting for the Mac to mirror this pane…")
                             : "Connecting…")
                            .font(Theme.font(Theme.ui(13), .medium))
                            .foregroundStyle(Color(white: 0.6))
                            .padding(12)
                    }
                }
                // Pinned to the top left, the way a terminal starts.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { typing = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attention: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.ui(12), weight: .bold))
            Text("\(pane.agentTool ?? "The agent") is waiting for you")
                .font(Theme.font(Theme.ui(12.5), .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Status.attention)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.Status.attention.opacity(0.12))
    }

    // MARK: - Keys

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Self.keys, id: \.name) { key in
                    Button {
                        Haptics.shared.fire(.light)
                        Task { await link.key(key.name, into: pane.id) }
                    } label: {
                        Group {
                            if let symbol = key.symbol {
                                Image(systemName: symbol)
                                    .font(.system(size: Theme.ui(13), weight: .bold))
                            } else {
                                Text(key.label)
                                    .font(.system(size: Theme.ui(12), weight: .bold, design: .monospaced))
                            }
                        }
                        .foregroundStyle(Color(white: 0.92))
                        .frame(minWidth: 38, minHeight: 34)
                        .padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(PressablePill(scale: 0.9))
                }
                if typing {
                    Button {
                        typing = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: Theme.ui(13), weight: .bold))
                            .foregroundStyle(Color(white: 0.92))
                            .frame(minWidth: 38, minHeight: 34)
                            .padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(PressablePill(scale: 0.9))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.04))
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Type into the pane", text: $input)
                .font(.system(size: Theme.ui(14), design: .monospaced))
                .foregroundStyle(Color(white: 0.95))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($typing)
                .onSubmit { send(submit: true) }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.08)))
            Button {
                send(submit: false)
            } label: {
                Text("type")
                    .font(Theme.font(Theme.ui(12), .bold))
                    .foregroundStyle(Color(white: 0.9))
                    .frame(height: 38)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(PressablePill(scale: 0.92))
            .disabled(input.isEmpty)
            Button {
                send(submit: true)
            } label: {
                Image(systemName: "return")
                    .font(.system(size: Theme.ui(14), weight: .bold))
                    .foregroundStyle(Theme.Brand.ink)
                    .frame(width: 44, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.Brand.cream))
            }
            .buttonStyle(PressablePill(scale: 0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    private func send(submit: Bool) {
        let text = input
        input = ""
        Haptics.shared.fire(.light)
        Task {
            if text.isEmpty {
                if submit { await link.key("return", into: pane.id) }
            } else {
                await link.type(text, into: pane.id, submit: submit)
            }
        }
    }

    // MARK: - Attach, and keep attached

    private func run() async {
        let wantsPicture = prefs.panePicture
        await link.attach(pane.id, picture: wantsPicture)
        if wantsPicture {
            channel = await link.openPicture(of: pane.id) { data in
                connected = true
                if let data, let image = UIImage(data: data) { picture = image }
            }
        } else {
            channel = await link.openScreen(of: pane.id) { text in
                connected = true
                screen = text
            }
        }
        // The harness types a line, so the round trip is on film.
        if ProcessInfo.processInfo.environment["CONTERM_PANE"] != nil, generation == 0 {
            Task {
                try? await Task.sleep(for: .seconds(4))
                Logger(subsystem: "dev.conterm.ios", category: "tour").notice("tour: pane type")
                await link.type("echo hello from the phone", into: pane.id, submit: true)
            }
        }
        // The Mac's lease is three minutes; renew well inside it.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { break }
            await link.attach(pane.id, picture: wantsPicture)
        }
    }
}
