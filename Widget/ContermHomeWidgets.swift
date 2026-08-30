import SwiftUI
import WidgetKit

/// The WidgetKit wiring. Deliberately thin.
///
/// Everything about how these look lives in `ContermWidgetFaces`, which the
/// app compiles too — so the design is worked on by running the app's gallery
/// rather than by installing a widget and squinting at a home screen. All
/// this file does is fetch a snapshot and hand it over.
struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: ContermSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : ContermSnapshotStore.read()
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: ContermSnapshotStore.read())
        // One entry, refreshed on a slow cadence. Everything that changes
        // quickly on these faces — the uptime clocks — is drawn ticking by
        // the system from a fixed start date, so it stays right without
        // costing a single refresh. The app reloads timelines itself when a
        // session opens or closes, which is when the rest actually changes.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct ContermStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.conterm.ios.status", provider: SnapshotProvider()) { entry in
            // `containerBackground` has to sit on the view this closure
            // returns. Applied deeper — inside the router's switch — WidgetKit
            // does not find it, falls back to its own material, and the
            // terminal is drawn as a smaller square floating in the middle of
            // a grey one. The fill still varies by family, so it varies inside
            // the builder rather than by moving the modifier.
            ContermFaceRouter(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { FamilyGround() }
        }
        .configurationDisplayName("Conterm")
        .description("Live sessions, and anything waiting on you.")
        // The other half of the same problem. iOS 17 insets widget content by
        // a default margin, which on a full-bleed design is a border of
        // whatever is behind it. These faces do their own padding.
        .contentMarginsDisabled()
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

/// The ground, which differs by family: the terminal for the system sizes,
/// nothing at all for the accessory ones — those render as a tinted stencil
/// over the wallpaper, where an opaque near-black fill maps to nothing and
/// the widget reads as missing.
struct FamilyGround: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            Color.clear
        default:
            CT.bed
        }
    }
}

/// Picks the face for the family it was given.
struct ContermFaceRouter: View {
    @Environment(\.widgetFamily) private var family
    var snapshot: ContermSnapshot

    var body: some View {
        switch family {
        case .systemSmall: SmallFace(snapshot: snapshot)
        case .systemMedium: MediumFace(snapshot: snapshot)
        case .systemLarge, .systemExtraLarge: LargeFace(snapshot: snapshot)
        case .accessoryCircular: CircularFace(snapshot: snapshot)
        case .accessoryRectangular: RectangularFace(snapshot: snapshot)
        case .accessoryInline: InlineFace(snapshot: snapshot)
        @unknown default: SmallFace(snapshot: snapshot)
        }
    }
}
