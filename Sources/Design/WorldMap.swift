import SwiftUI

/// Where a time zone is, roughly: the city it is named after. Enough to put
/// a host on a small map; a zone that is not listed falls back to the
/// longitude its offset implies, on a middle latitude.
enum WorldAtlas {
    private static let cities: [String: (lat: Double, lon: Double)] = [
        "Europe/London": (51.5, -0.1), "Europe/Dublin": (53.3, -6.3), "Europe/Lisbon": (38.7, -9.1),
        "Europe/Madrid": (40.4, -3.7), "Europe/Paris": (48.9, 2.4), "Europe/Brussels": (50.8, 4.4),
        "Europe/Amsterdam": (52.4, 4.9), "Europe/Berlin": (52.5, 13.4), "Europe/Frankfurt": (50.1, 8.7),
        "Europe/Zurich": (47.4, 8.5), "Europe/Vienna": (48.2, 16.4), "Europe/Prague": (50.1, 14.4),
        "Europe/Warsaw": (52.2, 21.0), "Europe/Rome": (41.9, 12.5), "Europe/Milan": (45.5, 9.2),
        "Europe/Stockholm": (59.3, 18.1), "Europe/Oslo": (59.9, 10.8), "Europe/Copenhagen": (55.7, 12.6),
        "Europe/Helsinki": (60.2, 24.9), "Europe/Athens": (38.0, 23.7), "Europe/Istanbul": (41.0, 29.0),
        "Europe/Kiev": (50.5, 30.5), "Europe/Kyiv": (50.5, 30.5), "Europe/Moscow": (55.8, 37.6),
        "Europe/Bucharest": (44.4, 26.1), "Europe/Budapest": (47.5, 19.0), "Europe/Sofia": (42.7, 23.3),
        "Asia/Tehran": (35.7, 51.4), "Asia/Dubai": (25.2, 55.3), "Asia/Riyadh": (24.7, 46.7),
        "Asia/Baghdad": (33.3, 44.4), "Asia/Jerusalem": (31.8, 35.2), "Asia/Tel_Aviv": (32.1, 34.8),
        "Asia/Karachi": (24.9, 67.0), "Asia/Kolkata": (22.6, 88.4), "Asia/Calcutta": (22.6, 88.4),
        "Asia/Dhaka": (23.8, 90.4), "Asia/Bangkok": (13.8, 100.5), "Asia/Jakarta": (-6.2, 106.8),
        "Asia/Singapore": (1.3, 103.8), "Asia/Kuala_Lumpur": (3.1, 101.7), "Asia/Hong_Kong": (22.3, 114.2),
        "Asia/Shanghai": (31.2, 121.5), "Asia/Taipei": (25.0, 121.5), "Asia/Seoul": (37.6, 127.0),
        "Asia/Tokyo": (35.7, 139.7), "Asia/Manila": (14.6, 121.0), "Asia/Almaty": (43.2, 76.9),
        "Asia/Tashkent": (41.3, 69.2), "Asia/Yerevan": (40.2, 44.5), "Asia/Baku": (40.4, 49.9),
        "Asia/Tbilisi": (41.7, 44.8), "Asia/Kathmandu": (27.7, 85.3), "Asia/Colombo": (6.9, 79.9),
        "Asia/Ho_Chi_Minh": (10.8, 106.7), "Asia/Saigon": (10.8, 106.7), "Asia/Novosibirsk": (55.0, 82.9),
        "Asia/Yekaterinburg": (56.8, 60.6), "Asia/Vladivostok": (43.1, 131.9),
        "Africa/Cairo": (30.0, 31.2), "Africa/Johannesburg": (-26.2, 28.0), "Africa/Lagos": (6.5, 3.4),
        "Africa/Nairobi": (-1.3, 36.8), "Africa/Casablanca": (33.6, -7.6), "Africa/Algiers": (36.7, 3.1),
        "Africa/Addis_Ababa": (9.0, 38.7), "Africa/Accra": (5.6, -0.2),
        "America/New_York": (40.7, -74.0), "America/Toronto": (43.7, -79.4), "America/Chicago": (41.9, -87.6),
        "America/Denver": (39.7, -105.0), "America/Phoenix": (33.4, -112.1), "America/Los_Angeles": (34.1, -118.2),
        "America/Vancouver": (49.3, -123.1), "America/Mexico_City": (19.4, -99.1), "America/Bogota": (4.7, -74.1),
        "America/Lima": (-12.0, -77.0), "America/Santiago": (-33.4, -70.7), "America/Sao_Paulo": (-23.5, -46.6),
        "America/Argentina/Buenos_Aires": (-34.6, -58.4), "America/Buenos_Aires": (-34.6, -58.4),
        "America/Caracas": (10.5, -66.9), "America/Halifax": (44.6, -63.6), "America/Anchorage": (61.2, -149.9),
        "America/Montreal": (45.5, -73.6), "America/Detroit": (42.3, -83.0), "America/Edmonton": (53.5, -113.5),
        "America/Winnipeg": (49.9, -97.1), "America/Havana": (23.1, -82.4), "America/Panama": (9.0, -79.5),
        "Pacific/Honolulu": (21.3, -157.9), "Pacific/Auckland": (-36.8, 174.8), "Pacific/Fiji": (-18.1, 178.4),
        "Australia/Sydney": (-33.9, 151.2), "Australia/Melbourne": (-37.8, 145.0), "Australia/Brisbane": (-27.5, 153.0),
        "Australia/Perth": (-31.9, 115.9), "Australia/Adelaide": (-34.9, 138.6),
        "Atlantic/Reykjavik": (64.1, -21.9), "Atlantic/Azores": (37.7, -25.7),
        "Indian/Mauritius": (-20.2, 57.5), "Etc/UTC": (51.5, 0.0), "UTC": (51.5, 0.0),
    ]

    /// Coordinates for a zone, or from its offset when the zone is unknown.
    static func place(zone: String?, offsetMinutes: Int?) -> (lat: Double, lon: Double, exact: Bool)? {
        if let zone, let hit = cities[zone] { return (hit.lat, hit.lon, true) }
        if let offsetMinutes {
            let lon = max(-180, min(180, Double(offsetMinutes) / 60 * 15))
            return (24, lon, false)
        }
        return nil
    }
}

/// The world as a field of dots, the night side dimmed by where the sun is
/// right now, and the hosts on it. The dots sweep in from the west when the
/// map appears.
struct WorldMap: View {
    struct Pin: Identifiable, Equatable {
        let id: String
        let lat: Double
        let lon: Double
        let color: Color
        var label: String?
        var exact = true
    }

    var pins: [Pin]
    var dot: Color = Color.white.opacity(0.55)
    var night: Color = Color.white.opacity(0.16)
    var date = Date()

    @State private var revealed: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                WorldDots(revealed: revealed, sun: Self.subsolar(date), wantNight: false)
                    .fill(dot)
                WorldDots(revealed: revealed, sun: Self.subsolar(date), wantNight: true)
                    .fill(night)
                ForEach(Array(pins.enumerated()), id: \.element.id) { index, pin in
                    let x = (pin.lon + 180) / 360 * size.width
                    let y = (90 - pin.lat) / 180 * size.height
                    VStack(spacing: 3) {
                        Circle()
                            .fill(pin.color)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                            .overlay {
                                if !pin.exact {
                                    Circle().strokeBorder(pin.color.opacity(0.5),
                                                          style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                        .frame(width: 17, height: 17)
                                }
                            }
                        if let label = pin.label {
                            Text(label)
                                .font(Theme.font(Theme.ui(9), .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                                .fixedSize()
                        }
                    }
                    .position(x: x, y: y + (pin.label == nil ? 0 : 9))
                    .popIn(index, base: 0.7)
                }
            }
            .drawingGroup()
        }
        .aspectRatio(2, contentMode: .fit)
        .onAppear {
            guard !reduceMotion else { revealed = 1; return }
            withAnimation(.easeOut(duration: 1.3)) { revealed = 1 }
        }
    }

    /// Where the sun is overhead: its declination for the day and the
    /// longitude under it for the hour, in degrees.
    static func subsolar(_ date: Date) -> (lat: Double, lon: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let declination = -23.44 * cos(2 * .pi / 365 * (day + 10))
        let hours = Double(cal.component(.hour, from: date))
            + Double(cal.component(.minute, from: date)) / 60
        let lon = -(hours - 12) * 15
        return (declination, lon)
    }
}

/// The land dots, revealed west to east; either the daylit ones or the
/// night ones, so the two can take two colours.
private struct WorldDots: Shape {
    var revealed: CGFloat
    var sun: (lat: Double, lon: Double)
    var wantNight: Bool

    var animatableData: CGFloat {
        get { revealed }
        set { revealed = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = WorldMask.width, h = WorldMask.height
        let cw = rect.width / CGFloat(w), ch = rect.height / CGFloat(h)
        let r = min(cw, ch) * 0.3
        let last = Int(revealed * CGFloat(w))
        let sinD = sin(sun.lat * .pi / 180), cosD = cos(sun.lat * .pi / 180)
        for y in 0..<h {
            let lat = 90 - (Double(y) + 0.5) * 180 / Double(h)
            let sinL = sin(lat * .pi / 180), cosL = cos(lat * .pi / 180)
            let row = WorldMask.rows[y]
            var idx = row.startIndex
            for x in 0..<w {
                let land = row[idx] == "1"
                idx = row.index(after: idx)
                guard land, x < last else { continue }
                let lon = (Double(x) + 0.5) * 360 / Double(w) - 180
                let hourAngle = (lon - sun.lon) * .pi / 180
                let elevation = sinL * sinD + cosL * cosD * cos(hourAngle)
                let isNight = elevation < 0
                guard isNight == wantNight else { continue }
                let cx = rect.minX + (CGFloat(x) + 0.5) * cw
                let cy = rect.minY + (CGFloat(y) + 0.5) * ch
                path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        }
        return path
    }
}
