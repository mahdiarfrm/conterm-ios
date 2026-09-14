import SwiftUI

// MARK: - Conterm panels
//
// A panel is a card that carries one thing and, usually, a picture of it: a
// readout with the chart behind the number, a fleet count with bars, a cloud
// of container bubbles. They are the app's own widgets, and they are drawn
// the same way wherever they appear — on the home screen, on a host's
// overview, in the gallery: a rounded card, a small uppercase label with a
// glyph in the corner, the number large, the chart beneath it.
//
// They move the same way too. A panel arrives by focusing in from a blur,
// one after another down the screen (`arrive`), and what is inside it draws
// itself once the card is there: lines of a chart one by one, bubbles
// popping in across a cloud, a meter easing to its fill.

/// The bed a panel sits on. Glass and ink take the ground's colour; the
/// rest are their own, flat and saturated, with white type on all of them
/// but the cream, which carries ink. A column of panels reads as a set of
/// coloured cards rather than a wall of one material, and every one of
/// them sits on every ground.
enum PanelBed: Equatable {
    /// A translucent white tile with a lit rim, on the ground. For the
    /// panels that hold bubbles.
    case glass
    /// A warm near-black, for a chart that wants a dark field behind fine
    /// lines.
    case ink
    /// The cream sheet, with ink type: something read closely.
    case cream
    /// Green: something alive, going well.
    case grass
    /// Amber: something to notice.
    case amber
    /// Blue: the disks, the recent hosts.
    case azure
    /// Teal: the network, the machines nearby.
    case teal
    /// Violet: the containers, the podium.
    case violet

    /// The fill of a bed; nil for glass, which is drawn from the ground.
    var fill: Color? {
        switch self {
        case .glass: return nil
        case .ink: return Theme.inkBed
        case .cream: return Theme.Brand.cream
        case .grass: return Color(red: 0.11, green: 0.66, blue: 0.40)
        case .amber: return Color(red: 0.96, green: 0.58, blue: 0.08)
        case .azure: return Color(red: 0.14, green: 0.47, blue: 0.98)
        case .teal: return Color(red: 0.03, green: 0.58, blue: 0.64)
        case .violet: return Color(red: 0.52, green: 0.33, blue: 0.95)
        }
    }

    /// Whether type on this bed is ink.
    var isLight: Bool { self == .cream }
}

/// The card.
struct Panel<Content: View, Accessory: View>: View {
    let title: String?
    let symbol: String?
    let bed: PanelBed
    let padding: CGFloat
    let content: Content
    let accessory: Accessory

    init(_ title: String? = nil,
         symbol: String? = nil,
         bed: PanelBed = .glass,
         padding: CGFloat = 20,
         @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.symbol = symbol
        self.bed = bed
        self.padding = padding
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .center, spacing: 8) {
                    if let title { PanelLabel(title, symbol: symbol) }
                    Spacer(minLength: 0)
                    accessory
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelSurface(bed: bed))
    }
}

extension Panel where Accessory == EmptyView {
    init(_ title: String? = nil,
         symbol: String? = nil,
         bed: PanelBed = .glass,
         padding: CGFloat = 20,
         @ViewBuilder content: () -> Content) {
        self.init(title, symbol: symbol, bed: bed, padding: padding,
                  content: content, accessory: { EmptyView() })
    }
}

/// The card's surface, by bed. Every one is the same shape.
struct PanelSurface: ViewModifier {
    var bed: PanelBed
    var cornerRadius: CGFloat = Theme.cardCorner
    @State private var prefs = Preferences.shared

    /// The bed as it will be drawn: glass for everything when the setting
    /// says so.
    private var drawn: PanelBed { prefs.glassPanels ? .glass : bed }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let bed = drawn
        Group {
            switch bed {
            case .glass:
                content
                    .glassTile(cornerRadius: cornerRadius)
                    .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
            case .ink:
                content
                    .background(shape.fill(Theme.inkBed))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .overlay(
                        shape.stroke(
                            LinearGradient(colors: [.white.opacity(0.30), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 1)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false))
                    .environment(\.colorScheme, .dark)
                    .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
            case .cream:
                // The cream card: ink type and the ground's deep cut as its
                // action colour.
                content
                    .background(shape.fill(Theme.Brand.cream))
                    .overlay(
                        shape.stroke(
                            LinearGradient(colors: [.white.opacity(0.7), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 1)
                        .allowsHitTesting(false))
                    .clipShape(shape)
                    .environment(\.colorScheme, .light)
                    .tint(Theme.Brand.ink)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            case .grass, .amber, .azure, .teal, .violet:
                // A coloured card: its own flat fill, a soft top light, white
                // type. The fill morphs when the bed changes, so a panel that
                // turns amber because something needs noticing does so in
                // front of you.
                content
                    .background(shape.fill(bed.fill ?? Theme.Brand.cream))
                    .overlay(
                        shape.stroke(
                            LinearGradient(colors: [.white.opacity(0.35), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 1)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false))
                    .clipShape(shape)
                    .environment(\.colorScheme, .dark)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            }
        }
        .animation(Theme.Spring.morph, value: bed)
    }
}

extension View {
    /// Lay this content on a panel surface without the panel's header.
    func panelSurface(_ bed: PanelBed = .glass,
                      cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        modifier(PanelSurface(bed: bed, cornerRadius: cornerRadius))
    }
}

/// A glyph and a small uppercase word. Names a panel; never underlines it.
struct PanelLabel: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.textSecondary

    init(_ title: String, symbol: String? = nil, tint: Color = Theme.textSecondary) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(10), weight: .bold))
            }
            Text(title.uppercased())
                .font(Theme.font(Theme.ui(10.5), .bold))
                .tracking(1.0)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}

/// The number a panel is about, with its unit beside it and, when the
/// number is live, a small "NOW" tag — `62 BPM NOW`. The number rolls.
struct PanelReadout: View {
    let value: String
    var unit: String?
    var tag: String?
    var size: CGFloat = 34
    var tint: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(Theme.font(Theme.ui(size), .bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .rollingDigits(on: value)
            if let unit {
                Text(unit)
                    .font(Theme.font(Theme.ui(13), .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .morph(on: unit, alignment: .leading)
            }
            if let tag {
                Text(tag.uppercased())
                    .font(Theme.font(Theme.ui(9), .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(Theme.stroke))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            }
        }
    }
}

/// A word in a translucent capsule with a status dot: a container, a host,
/// a chip of anything that is one of several. `lit` is the one that is
/// running, or chosen, or under the finger.
struct Bubble: View {
    let text: String
    var dot: Color?
    var symbol: String?
    var lit: Bool = false
    var detail: String?

    init(_ text: String, dot: Color? = nil, symbol: String? = nil,
         lit: Bool = false, detail: String? = nil) {
        self.text = text
        self.dot = dot
        self.symbol = symbol
        self.lit = lit
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 7) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(11), weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(text)
                .font(Theme.font(Theme.ui(13), .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .morph(on: detail, alignment: .leading)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .glassPill(selected: lit)
        .contentShape(Capsule(style: .continuous))
    }
}

/// Lays subviews out in rows, wrapping like words. There is no `FlowLayout`
/// in SwiftUI, and a horizontal scroll view for two or three short chips
/// reads as broken.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A hairline between rows inside a panel.
struct PanelRule: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.5)
    }
}
