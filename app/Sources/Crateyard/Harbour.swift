import SwiftUI

/// The landing page's harbour, live: every running container is a box on deck, and the ship sits lower as it fills.
struct HarbourScene: View {
    let running: [Container]
    var onSelect: (Container) -> Void = { _ in }
    private let box = CGSize(width: 78, height: 30)
    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let hullW = min(w - 40, 620)
            let hullH: CGFloat = 30
            let perRow = max(1, Int((hullW - 96) / (box.width + gap)))
            let shown = Array(running.prefix(perRow))
            let waterline = h * 0.68
            let sink = CGFloat(min(shown.count, 8)) * 1.5

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                        CargoBox(name: c.shortName, colorKey: c.name)
                            .frame(width: box.width, height: box.height)
                            .onTapGesture { onSelect(c) }
                            .help(c.name)
                            .offset(x: 24 + CGFloat(i) * (box.width + gap), y: -(box.height + 3))
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    RoundedRectangle(cornerRadius: 3).fill(Theme.text.opacity(0.85))
                        .frame(width: 40, height: 30)
                        .offset(x: hullW - 64, y: -30)
                    Hull().fill(Theme.text.opacity(0.92)).frame(width: hullW, height: hullH)
                }
                .offset(x: (w - hullW) / 2, y: waterline - hullH * 0.5 + sink)

                Rectangle().fill(Theme.sea.opacity(0.92))
                    .frame(width: w, height: h - waterline)
                    .offset(y: waterline)

                if running.count > shown.count {
                    Text("+\(running.count - shown.count) more")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.soft)
                        .offset(x: 4, y: 4)
                }
                if running.isEmpty {
                    Text("Empty deck. Containers you start show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .animation(.spring(duration: 0.7, bounce: 0.2), value: shown.map(\.id))
        }
    }
}

private struct Hull: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 22, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 14, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A shipping container in the container's colour, with corrugation lines and its name.
struct CargoBox: View {
    let name: String
    let colorKey: String

    var body: some View {
        ZStack {
            Theme.cargoColor(for: colorKey)
            HStack(spacing: 5) { ForEach(0..<6, id: \.self) { _ in Rectangle().fill(.black.opacity(0.08)).frame(width: 1.5) } }
                .padding(.vertical, 4)
            Text(name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
