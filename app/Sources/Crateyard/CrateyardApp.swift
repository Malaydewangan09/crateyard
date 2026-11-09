import AppKit
import SwiftUI

@main
struct CrateyardApp: App {
    @State private var engine = Engine()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(engine)
        } label: {
            MenuBarLabel(isRunning: engine.phase == .running)
        }
        .menuBarExtraStyle(.window)

        Window("Crateyard", id: "main") {
            Dashboard()
                .environment(engine)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 900)
    }
}

/// The menu bar icon. It also opens the main window once at launch, so a first-time user sees Crateyard instead of nothing.
struct MenuBarLabel: View {
    let isRunning: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var hasOpened = false

    var body: some View {
        Image(nsImage: MenuBarIcon.image(isRunning: isRunning))
            .task {
                guard !hasOpened else { return }
                hasOpened = true
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// The menu bar icon: Crateyard's mark as a template image so the menu bar tints it. A faded container means the engine is stopped.
enum MenuBarIcon {
    static func image(isRunning: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(CrateyardGlyph.line(in: rect))
            ctx.fillPath()
            ctx.setFillColor(NSColor.black.withAlphaComponent(isRunning ? 1 : 0.35).cgColor)
            ctx.addPath(CrateyardGlyph.container(in: rect))
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct PhaseLabel: View {
    let phase: EnginePhase

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(phase.color).frame(width: 7, height: 7)
            Text(phase.label)
        }
    }
}
