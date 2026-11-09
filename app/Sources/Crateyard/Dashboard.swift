import Charts
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case images = "Images"
    case volumes = "Volumes"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.down.right"
        case .volumes: return "externaldrive"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .containers: return "1"
        case .images: return "2"
        case .volumes: return "3"
        }
    }
}

/// The main window: a sidebar for what Docker holds, and the list for the chosen kind.
struct Dashboard: View {
    @Environment(Engine.self) private var engine
    @State private var section: SidebarItem = .containers
    @State private var inspecting: Inspection?

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider().overlay(Theme.line)
            if engine.phase == .notInstalled || engine.phase == .installing {
                SetupView()
            } else if engine.phase != .running {
                Idle()
            } else {
                HStack(spacing: 0) {
                    Sidebar(section: $section)
                    Divider().overlay(Theme.line)
                    switch section {
                    case .containers: ContainersPage(inspecting: $inspecting)
                    case .images: ImagesPage()
                    case .volumes: VolumesPage()
                    }
                }
            }
        }
        .background(Theme.night)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .sheet(item: $inspecting) { i in ContainerSheet(container: i.container, tab: i.tab) }
        // Details and logs come from Docker, and asking it anything wakes a sleeping VM.
        .onChange(of: engine.phase) { if engine.phase != .running { inspecting = nil } }
        .onAppear { engine.isWindowVisible = true }
        .onDisappear { engine.isWindowVisible = false }
        .alert("Something went wrong", isPresented: Binding(get: { engine.lastError != nil }, set: { if !$0 { engine.lastError = nil } })) {
            Button("OK") { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Environment(Engine.self) private var engine
    @Binding var section: SidebarItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarItem.allCases) { s in
                Button { section = s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol).frame(width: 18)
                        Text(s.rawValue)
                        Spacer()
                        Text(count(s)).foregroundStyle(Theme.soft).monospacedDigit()
                    }
                    .font(.system(size: 13, weight: section == s ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(section == s ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(s.shortcut, modifiers: .command)
                .help("\(s.rawValue) ⌘\(s.shortcut.character)")
            }
            Spacer()
            if let st = engine.status {
                VStack(alignment: .leading, spacing: 6) {
                    Fact(label: "Disk on your Mac", value: Bytes.disk(Int64(st.dataDiskBytes)))
                    Fact(label: "Last boot", value: String(format: "%.1f s", st.bootSeconds))
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(12)
        .frame(width: 210)
        .background(Theme.surface)
    }

    private func count(_ s: SidebarItem) -> String {
        switch s {
        case .containers: return "\(engine.runningCount)/\(engine.containers.count)"
        case .images: return "\(engine.images.count)"
        case .volumes: return "\(engine.volumes.count)"
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.soft)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }
}

// MARK: Header

struct Header: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        HStack(spacing: 14) {
            CrateyardMark(size: 24)
            Text("Crateyard").font(.system(size: 17, weight: .semibold))
            StatusPill(phase: engine.phase)
            if let st = engine.status, engine.phase == .running {
                MemorySummary(status: st)
                if let at = st.sleepsAt { SleepCountdown(at: at) }
            }
            if let warning = engine.dockerWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.buoy).lineLimit(1)
            }
            Spacer()
            EngineButton()
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }
}

/// Sleep is automatic, so say when it will happen instead of letting the VM vanish by surprise.
private struct SleepCountdown: View {
    let at: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let minutes = Int(ceil(max(0, at.timeIntervalSince(context.date)) / 60))
            Label(minutes <= 1 ? "Sleeps in under a minute" : "Sleeps in \(minutes) min", systemImage: "moon.zzz")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.soft)
                .help("Nothing is running, so Crateyard will stop the VM and give its memory back to macOS. Any docker command wakes it in a few seconds.")
        }
    }
}

/// One number people ask about, what Crateyard costs their Mac, with the detail one click away.
private struct MemorySummary: View {
    let status: EngineStatus
    @State private var isShowingDetail = false

    var body: some View {
        Button { isShowingDetail.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                Text("Using \(Bytes.memory(status.vmFootprintBytes)) of your Mac's memory")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.soft)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingDetail, arrowEdge: .bottom) { MemoryDetail() }
    }
}

private struct MemoryDetail: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let st = engine.status {
                Text("Crateyard is using \(Bytes.memory(st.vmFootprintBytes)) of your Mac's memory, out of an \(Bytes.memory(st.memoryLimitBytes)) limit.")
                    .font(.system(size: 13, weight: .medium))
                Text("Linux needs \(Bytes.memory(st.guestUsedBytes)) of it right now. The rest is memory it used earlier and macOS cannot take back while the VM runs. It all comes back when Crateyard sleeps, after 5 minutes with nothing running.")
                    .font(.system(size: 12)).foregroundStyle(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MemoryChart()
        }
        .padding(18)
        .frame(width: 460)
        .background(Theme.night)
        .preferredColorScheme(.dark)
    }
}

private struct MemoryChart: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(engine.history) { s in
                AreaMark(x: .value("Time", s.at), y: .value("GB", gb(s.vm)), series: .value("Series", "Mac \(s.segment)"))
                    .foregroundStyle(Theme.buoy.opacity(0.18))
                LineMark(x: .value("Time", s.at), y: .value("GB", gb(s.vm)), series: .value("Series", "Mac \(s.segment)"))
                    .foregroundStyle(Theme.buoy)
                LineMark(x: .value("Time", s.at), y: .value("GB", gb(s.guest)), series: .value("Series", "Linux \(s.segment)"))
                    .foregroundStyle(Theme.ok)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f GB", d)).foregroundStyle(Theme.dim) } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.dim) } }
            .chartYScale(domain: 0...max(1, (engine.history.map { gb($0.vm) }.max() ?? 1) * 1.2))
            .frame(height: 140)
            HStack(spacing: 16) {
                Legend(color: Theme.buoy, text: "your Mac's memory")
                Legend(color: Theme.ok, text: "what Linux needs")
                Spacer()
                Text("last 10 minutes").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
        }
    }

    private func gb(_ b: UInt64) -> Double { Double(b) / 1_073_741_824 }
}

private struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 3)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.soft)
        }
    }
}

struct StatusPill: View {
    let phase: EnginePhase

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(phase.color).frame(width: 7, height: 7)
            Text(phase.label).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(phase.color.opacity(0.14), in: Capsule())
        .foregroundStyle(phase.color)
    }
}

struct EngineButton: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        switch engine.phase {
        case .stopped:
            Button { engine.start() } label: { Label("Start", systemImage: "play.fill") }
                .buttonStyle(Pill(fill: Theme.text, text: Theme.night))
        case .running:
            HStack(spacing: 8) {
                Button { Task { await engine.sleepNow() } } label: { Label("Sleep", systemImage: "moon.zzz") }
                    .buttonStyle(Pill(fill: Theme.raised, text: Theme.text))
                    .help("Stop the VM and give its memory back. Any docker command wakes it.")
                Button { Task { await engine.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(Pill(fill: Theme.raised, text: Theme.text))
                    .help("Shut Crateyard down. Running containers stop.")
            }
        case .sleeping:
            Button { Task { await engine.wake() } } label: { Label("Wake", systemImage: "sun.max") }
                .buttonStyle(Pill(fill: Theme.text, text: Theme.night))
        default:
            ProgressView().controlSize(.small)
        }
    }
}

struct Pill: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .foregroundStyle(text)
    }
}

// MARK: Not running and setup

struct Idle: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            CrateyardMark(size: 64, color: engine.phase == .starting ? Theme.buoy : Theme.soft)
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).foregroundStyle(Theme.soft).multilineTextAlignment(.center).frame(maxWidth: 440)
            if engine.phase == .stopped {
                Button { engine.start() } label: { Label("Start Crateyard", systemImage: "play.fill") }
                    .buttonStyle(Pill(fill: Theme.text, text: Theme.night))
                    .keyboardShortcut(.defaultAction)
            } else if engine.phase == .sleeping {
                Button { Task { await engine.wake() } } label: { Label("Wake now", systemImage: "sun.max") }
                    .buttonStyle(Pill(fill: Theme.text, text: Theme.night))
                    .keyboardShortcut(.defaultAction)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch engine.phase {
        case .stopped: return "Crateyard is resting"
        case .sleeping: return "Crateyard is asleep"
        case .starting: return "Booting the VM"
        case .checking: return "Checking the engine"
        default: return "Shutting down"
        }
    }

    private var detail: String {
        if let failure = engine.status?.lastError, engine.phase == .sleeping {
            return "The VM could not wake: \(failure) Try Wake now, or see ~/.crateyard/crateyardd.log."
        }
        switch engine.phase {
        case .stopped: return "Start it to run containers. It boots in about 3 seconds."
        case .sleeping: return "Nothing ran for 5 minutes, so the VM is stopped and its memory is back with macOS. Your next docker command wakes it in a few seconds."
        default: return "This takes a few seconds."
        }
    }
}

struct SetupView: View {
    @Environment(Engine.self) private var engine
    @State private var mirror = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Crateyard").font(.system(size: 24, weight: .semibold))
            Text("Crateyard builds a small Linux VM with Docker inside, once. It downloads about 200 MB from Alpine Linux and takes a few minutes.")
                .foregroundStyle(Theme.soft)
            HStack {
                TextField("Alpine mirror (optional), e.g. https://mirror.leaseweb.com/alpine", text: $mirror)
                    .textFieldStyle(.roundedBorder)
                Button(engine.phase == .installing ? "Building…" : "Build VM") { Task { await engine.install(mirror: mirror) } }
                    .buttonStyle(Pill(fill: Theme.text, text: Theme.night))
                    .disabled(engine.phase == .installing)
            }
            if engine.phase == .installing || !engine.setupLog.isEmpty {
                ScrollView {
                    Text(engine.setupLog)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.soft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
        }
        .padding(28)
    }
}
