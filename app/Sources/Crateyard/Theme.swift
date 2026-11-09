import SwiftUI

/// Crateyard's colours, shared with the landing page: a night harbour with one buoy-orange accent.
enum Theme {
    static let night = Color(red: 0.043, green: 0.063, blue: 0.086)
    static let surface = Color(red: 0.070, green: 0.090, blue: 0.118)
    static let raised = Color(red: 0.094, green: 0.118, blue: 0.149)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.933, green: 0.941, blue: 0.949)
    static let soft = Color(red: 0.604, green: 0.639, blue: 0.678)
    static let dim = Color(red: 0.357, green: 0.388, blue: 0.424)
    static let buoy = Color(red: 1.0, green: 0.416, blue: 0.239)
    static let sea = Color(red: 0.122, green: 0.322, blue: 0.463)
    static let ok = Color(red: 0.169, green: 0.702, blue: 0.639)
    /// Row states. A clear white wash reads as selected on the dark ground without the system accent's blue.
    static let selection = Color.white.opacity(0.10)
    static let selectionEdge = Color.white.opacity(0.16)
    static let hover = Color.white.opacity(0.04)
    static let danger = Color(red: 0.937, green: 0.408, blue: 0.408)

    /// Container colours from the landing page's harbour. A container keeps the same colour across refreshes.
    static let cargo: [Color] = [
        buoy,
        ok,
        Color(red: 0.894, green: 0.714, blue: 0.376),
        Color(red: 0.424, green: 0.549, blue: 1.0),
        Color(red: 0.851, green: 0.325, blue: 0.310),
    ]

    static func cargoColor(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return cargo[sum % cargo.count]
    }
}

extension EnginePhase {
    var label: String {
        switch self {
        case .checking: return "Checking"
        case .notInstalled: return "Not set up"
        case .installing: return "Building VM"
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .sleeping: return "Sleeping"
        }
    }

    var color: Color {
        switch self {
        case .running: return Theme.ok
        case .starting, .stopping, .installing: return Theme.buoy
        case .checking, .stopped, .notInstalled, .sleeping: return Theme.soft
        }
    }
}

/// Crateyard's mark in a 64-unit square, y down: a container resting on the load line.
/// Fill it even-odd so the three corrugation slots are cut out.
enum CrateyardGlyph {
    static func container(in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        add(p, rect, 15, 18, 34, 22, 2)
        for x in [22.0, 30.5, 39.0] { add(p, rect, x, 22, 3, 14, 0) }
        return p
    }

    static func line(in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        add(p, rect, 4, 43, 56, 4.5, 2.25)
        return p
    }

    private static func add(_ p: CGMutablePath, _ rect: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) {
        let s = rect.width / 64
        p.addRoundedRect(in: CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s), cornerWidth: radius * s, cornerHeight: radius * s)
    }
}

struct CrateyardMark: View {
    var size: CGFloat = 18
    var color: Color = Theme.buoy

    var body: some View {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ZStack {
            Path(CrateyardGlyph.container(in: rect)).fill(color, style: FillStyle(eoFill: true))
            Path(CrateyardGlyph.line(in: rect)).fill(color)
        }
        .frame(width: size, height: size)
    }
}
