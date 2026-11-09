import SwiftUI

/// The menu bar panel: state, real memory, running containers with their ports, and start or stop.
struct MenuPanel: View {
    @Environment(Engine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Crateyard").font(.headline)
                Spacer()
                PhaseLabel(phase: engine.phase).font(.callout).foregroundStyle(.secondary)
            }

            if let st = engine.status, engine.phase == .running {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("VM memory").foregroundStyle(.secondary)
                        Text(Bytes.memory(st.vmFootprintBytes)).monospacedDigit()
                    }
                    GridRow {
                        Text("Disk").foregroundStyle(.secondary)
                        Text(Bytes.disk(Int64(st.dataDiskBytes))).monospacedDigit()
                    }
                    GridRow {
                        Text("Containers").foregroundStyle(.secondary)
                        Text("\(engine.runningCount) running").monospacedDigit()
                    }
                }
                .font(.callout)

                let running = engine.containers.filter(\.isRunning)
                if !running.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(running.prefix(8)) { c in
                            HStack {
                                Text(c.name).lineLimit(1)
                                Spacer()
                                ForEach(c.publishedPorts, id: \.self) { p in
                                    Button { engine.open(p.localURL) } label: { Text(verbatim: ":\(p.PublicPort ?? 0)") }
                                        .buttonStyle(.link)
                                }
                            }
                            .font(.callout)
                        }
                        if running.count > 8 {
                            Text("+\(running.count - 8) more in Crateyard").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if engine.phase == .notInstalled {
                Text("Crateyard needs to build its Linux VM once. Open Crateyard to set it up.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger).lineLimit(3)
            }

            Divider()
            HStack {
                switch engine.phase {
                case .stopped:
                    Button("Start") { engine.start() }.keyboardShortcut(.defaultAction)
                case .running:
                    Button("Sleep") { Task { await engine.sleepNow() } }
                        .help("Stop the VM and give its memory back. Any docker command wakes it.")
                    Button("Stop") { Task { await engine.stop() } }
                case .sleeping:
                    Button("Wake") { Task { await engine.wake() } }
                default:
                    EmptyView()
                }
                Spacer()
                Button("Open Crateyard") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
