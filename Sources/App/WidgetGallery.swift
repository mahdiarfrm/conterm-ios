import SwiftUI

/// Every widget face, at its real size, inside the app.
///
/// Widget design is otherwise a miserable loop: change a number, build,
/// install, remove the widget from the home screen, add it back, squint. The
/// faces live in `Shared/` precisely so this screen can render the same views
/// the extension does, which turns that loop into build-and-run.
///
/// Reachable with `CONTERM_WIDGETS=1`, and from Settings, because it is also
/// the honest answer to "what will this look like on my home screen".
struct WidgetGallery: View {
    /// The real sizes on a 402pt-wide phone. Hardcoded rather than derived:
    /// the point is to see the face at the size the system will give it, not
    /// at the size this screen happens to be.
    private let small = CGSize(width: 170, height: 170)
    private let medium = CGSize(width: 364, height: 170)
    private let large = CGSize(width: 364, height: 382)

    @State private var useLiveData = false

    /// `CONTERM_WIDGETS=2` shows only the tall faces, and `=3` only the Live
    /// Activity, which is the only way to see them without a scroll gesture
    /// the tooling can't make.
    private var mode: String { ProcessInfo.processInfo.environment["CONTERM_WIDGETS"] ?? "1" }
    private var compact: Bool { mode != "1" }
    private var activityOnly: Bool { mode == "3" }

    private var snapshot: ContermSnapshot {
        useLiveData ? ContermSnapshotStore.read() : .preview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                source

                if !compact {
                group("Small") {
                    SmallFace(snapshot: snapshot)
                        .frame(width: small.width, height: small.height)
                }
                group("Medium") {
                    MediumFace(snapshot: snapshot)
                        .frame(width: medium.width, height: medium.height)
                }
                }
                if !activityOnly {
                group("Large") {
                    LargeFace(snapshot: snapshot)
                        .frame(width: large.width, height: large.height)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                }
                group("Live Activity") {
                    VStack(alignment: .leading, spacing: 12) {
                        SessionFace.Banner(attributes: Self.activityAttributes,
                                           state: Self.activityState,
                                           palette: CT.palette(snapshot.ground))
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .frame(width: medium.width)
                        // The island's expanded regions, laid out the way the
                        // system does: leading and trailing on one row, the
                        // bottom beneath, in its black.
                        VStack(spacing: 0) {
                            HStack(alignment: .top) {
                                SessionFace.Leading(attributes: Self.activityAttributes,
                                                    state: Self.activityState)
                                Spacer(minLength: 0)
                                SessionFace.Trailing(attributes: Self.activityAttributes,
                                                     state: Self.activityState)
                            }
                            SessionFace.Bottom(attributes: Self.activityAttributes,
                                               state: Self.activityState)
                        }
                        .padding(14)
                        .frame(width: medium.width)
                        .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.black))
                        HStack(spacing: 0) {
                            SessionFace.CompactMark(color: CT.palette(snapshot.ground).lights[0])
                            Spacer()
                            SessionFace.CompactClock(attributes: Self.activityAttributes)
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 200, height: 37)
                        .background(Capsule().fill(.black))
                    }
                }
                if !activityOnly {
                group("Lock screen") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            CircularFace(snapshot: snapshot)
                                .frame(width: 72, height: 72)
                            RectangularFace(snapshot: snapshot)
                                .frame(width: 160, height: 72, alignment: .leading)
                        }
                        InlineFace(snapshot: snapshot)
                            .font(Theme.font(15, .semibold))
                    }
                    // The lock screen renders accessory widgets as a single
                    // tinted stencil, so previewing them in colour would be a
                    // lie about what you will actually see.
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08)))
                }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .brandGround()
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let activityAttributes = SessionActivityAttributes(
        hostAlias: "sibche-prod", target: "root@sibche-mobin-prod", ordinal: 1,
        startedAt: Date().addingTimeInterval(-4_357))
    private static let activityState = SessionActivityAttributes.ContentState(
        phase: .connected, title: "root@sibche-mobin-prod: ~/app",
        bytesIn: 294_120, bytesOut: 12_400,
        pulse: [0.1, 0.2, 0.05, 0.6, 1.0, 0.4, 0.2, 0.3, 0.8, 0.5, 0.15, 0.35],
        detail: nil)

    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $useLiveData) {
                Text("Sample").tag(false)
                Text("Live").tag(true)
            }
            .pickerStyle(.segmented)

            Text(ContermSnapshotStore.isShared
                 ? "Sharing with the widget extension."
                 : "No App Group — the extension can't read this yet, so widgets "
                 + "on the home screen show sample data.")
                .font(Theme.font(11, .medium))
                .foregroundStyle(ContermSnapshotStore.isShared
                                 ? Theme.textSecondary : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
