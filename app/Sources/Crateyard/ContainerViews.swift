import AppKit
import Charts
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case logs = "Logs"
    var id: String { rawValue }
}

struct Inspection: Identifiable {
    let container: Container
    let tab: DetailTab
    var id: String { container.Id }
}

// MARK: Containers page

struct ContainersPage: View {
    @Environment(Engine.self) private var engine
    @Binding var inspecting: Inspection?
    @State private var query = ""
    @State private var isRunningOnly = false
    @State private var collapsed: Set<String> = []
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var removing: [Container] = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let groups = self.groups
        VStack(spacing: 0) {
            HarbourScene(running: engine.containers.filter(\.isRunning)) { c in
                inspecting = Inspection(container: c, tab: .overview)
            }
            .frame(height: 84)
            .padding([.horizontal, .top], 16)
            toolbar
            ColumnHeader()
            Divider().overlay(Theme.line)
            if engine.containers.isEmpty {
                EmptyState(title: "No containers yet", detail: "Run one from Terminal and it shows up here.", command: "docker run -d -p 8080:80 nginx")
            } else if groups.isEmpty {
                EmptyState(title: "Nothing matches", detail: isRunningOnly ? "No running container matches. Try All." : "Try another name or image.", command: nil)
            } else {
                // Crateyard's own list instead of List: the system one draws selection in the accent colour and its outline cells
                // relayout on hover, which made the Compose row flicker.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(groups, id: \.key) { group in
                                if group.isNamed {
                                    ProjectRow(name: group.key, all: group.all, isCollapsed: collapsed.contains(group.key)) {
                                        if collapsed.remove(group.key) == nil { collapsed.insert(group.key) }
                                    }
                                    Divider().overlay(Theme.line).padding(.leading, 16)
                                }
                                if !collapsed.contains(group.key) {
                                    ForEach(group.members) { c in
                                        row(c, isNested: group.isNamed).id(c.Id)
                                        Divider().overlay(Theme.line).padding(.leading, group.isNamed ? 44 : 16)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) { moveSelection(-1, proxy); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1, proxy); return .handled }
                    .onKeyPress(.return) {
                        guard let c = containers(selection).first else { return .ignored }
                        inspecting = Inspection(container: c, tab: .overview)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        selection = []
                        return .handled
                    }
                    .onDeleteCommand { removing = containers(selection) }
                }
            }
            PageFooter(text: summary)
        }
        .background {
            Button("") { isSearchFocused = true }.keyboardShortcut("f").hidden()
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })) {
            Button(removing.count == 1 ? "Remove container" : "Remove \(removing.count) containers", role: .destructive) {
                let cs = removing
                selection.subtract(cs.map(\.Id))
                Task { await engine.containerAction(cs, .remove) }
            }
        } message: {
            Text(removing.contains(where: \.isRunning) ? "Running ones are stopped first. Volumes are kept." : "Volumes are kept.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            SearchField(text: $query, prompt: "Search containers", isFocused: $isSearchFocused)
            let picked = containers(selection)
            if picked.count > 1 {
                Text("\(picked.count) selected").font(.system(size: 12)).foregroundStyle(Theme.soft).fixedSize()
                if picked.contains(where: { !$0.isRunning }) {
                    Button("Start") { Task { await engine.containerAction(picked.filter { !$0.isRunning }, .start) } }.buttonStyle(RowButton())
                }
                if picked.contains(where: \.isRunning) {
                    Button("Stop") { Task { await engine.containerAction(picked.filter(\.isRunning), .stop) } }.buttonStyle(RowButton())
                }
                Button("Remove") { removing = picked }.buttonStyle(RowButton(isDestructive: true))
            }
            Picker("", selection: $isRunningOnly) {
                Text("All").tag(false)
                Text("Running").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(16)
    }

    private func row(_ c: Container, isNested: Bool) -> some View {
        ContainerRow(container: c, isNested: isNested, isSelected: selection.contains(c.Id), inspecting: $inspecting)
            .onTapGesture { click(c) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { inspecting = Inspection(container: c, tab: .overview) })
            .contextMenu { menu(for: selection.contains(c.Id) ? containers(selection) : [c]) }
    }

    /// Finder rules: a click selects one, Command adds or removes one, Shift extends from the last plain click.
    private func click(_ c: Container) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.remove(c.Id) == nil { selection.insert(c.Id) }
            anchor = c.Id
        } else if flags.contains(.shift), let anchor, let from = visibleIDs.firstIndex(of: anchor), let to = visibleIDs.firstIndex(of: c.Id) {
            selection = Set(visibleIDs[min(from, to)...max(from, to)])
        } else {
            selection = [c.Id]
            anchor = c.Id
        }
    }

    private func moveSelection(_ step: Int, _ proxy: ScrollViewProxy) {
        let ids = visibleIDs
        guard !ids.isEmpty else { return }
        let current = ids.lastIndex { selection.contains($0) }
        let next = current.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
        selection = [ids[next]]
        anchor = ids[next]
        proxy.scrollTo(ids[next])
    }

    /// Container ids in the order they are drawn, skipping collapsed projects.
    private var visibleIDs: [String] {
        groups.flatMap { collapsed.contains($0.key) ? [] : $0.members.map(\.Id) }
    }

    @ViewBuilder
    private func menu(for cs: [Container]) -> some View {
        if cs.count == 1, let c = cs.first {
            Button("Show Details") { inspecting = Inspection(container: c, tab: .overview) }
            Button("Show Logs") { inspecting = Inspection(container: c, tab: .logs) }
            Divider()
            if let url = c.publishedPorts.first?.localURL, c.isRunning {
                Button("Open \(url.host() ?? "localhost"):\(url.port ?? 0)") { engine.open(url) }
            }
            Button("Copy ID") { copy(c.Id) }
            Divider()
        }
        if cs.contains(where: { !$0.isRunning }) {
            Button("Start") { Task { await engine.containerAction(cs.filter { !$0.isRunning }, .start) } }
        }
        if cs.contains(where: \.isRunning) {
            Button("Stop") { Task { await engine.containerAction(cs.filter(\.isRunning), .stop) } }
            Button("Restart") { Task { await engine.containerAction(cs.filter(\.isRunning), .restart) } }
        }
        Divider()
        Button(cs.count == 1 ? "Remove…" : "Remove \(cs.count) Containers…", role: .destructive) { removing = cs }
    }

    private var summary: String {
        guard !engine.containers.isEmpty else { return "" }
        let base = "\(engine.runningCount) of \(engine.containers.count) running"
        guard engine.isWindowVisible, !engine.usage.isEmpty else { return base + "." }
        let memory = engine.usage.values.reduce(0) { $0 + $1.memoryBytes }
        let cpu = engine.usage.values.reduce(0) { $0 + $1.cpuPercent }
        return base + ", using \(Bytes.small(memory)) and \(String(format: "%.1f%%", cpu)) CPU between them."
    }

    private var removeTitle: String {
        removing.count == 1 ? "Remove \(removing[0].name)?" : "Remove \(removing.count) containers?"
    }

    private func containers(_ ids: Set<String>) -> [Container] {
        engine.containers.filter { ids.contains($0.Id) }
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) }, set: { if $0 { collapsed.remove(key) } else { collapsed.insert(key) } })
    }

    private struct Group {
        let key: String
        let members: [Container]
        let all: [Container]
        var isNamed: Bool { !key.isEmpty }
    }

    /// Compose projects first by name, then standalone containers at the top level.
    private var groups: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let byProject = Dictionary(grouping: engine.containers) { $0.composeProject ?? "" }
        return byProject.keys.sorted { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }.compactMap { key in
            let all = byProject[key] ?? []
            let members = all.filter { c in
                (!isRunningOnly || c.isRunning)
                    && (q.isEmpty || c.name.localizedCaseInsensitiveContains(q) || c.Image.localizedCaseInsensitiveContains(q) || key.localizedCaseInsensitiveContains(q))
            }
            return members.isEmpty ? nil : Group(key: key, members: members, all: all)
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private enum Column {
    static let status: CGFloat = 150
    static let ports: CGFloat = 150
    static let cpu: CGFloat = 60
    static let memory: CGFloat = 80
    static let actions: CGFloat = 116
}

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("STATUS").frame(width: Column.status, alignment: .leading)
            Text("PORTS").frame(width: Column.ports, alignment: .leading)
            Text("CPU").frame(width: Column.cpu, alignment: .trailing)
            Text("MEMORY").frame(width: Column.memory, alignment: .trailing)
            Color.clear.frame(width: Column.actions, height: 1)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .tracking(0.6)
        .foregroundStyle(Theme.dim)
        // Lines up with the list's own row inset.
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}

/// A Compose project: its containers sit under it, and its numbers are their sums.
private struct ProjectRow: View {
    @Environment(Engine.self) private var engine
    let name: String
    let all: [Container]
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        let running = all.filter(\.isRunning)
        let usage = running.compactMap { engine.usage[$0.Id] }
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.soft)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
                Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.soft)
                Text(name).font(.system(size: 13, weight: .semibold))
                Text("Compose").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.soft)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Theme.line))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(running.count) of \(all.count) running")
                .foregroundStyle(running.isEmpty ? Theme.soft : Theme.text)
                .frame(width: Column.status, alignment: .leading)
            Color.clear.frame(width: Column.ports, height: 1)
            Text(running.isEmpty ? "" : String(format: "%.1f%%", usage.reduce(0) { $0 + $1.cpuPercent }))
                .frame(width: Column.cpu, alignment: .trailing)
            Text(running.isEmpty ? "" : Bytes.small(usage.reduce(0) { $0 + $1.memoryBytes }))
                .frame(width: Column.memory, alignment: .trailing)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                // Always laid out and only faded, so hovering never changes the row's size.
                Group {
                    if running.count < all.count {
                        Button("Start all") { Task { await engine.containerAction(all.filter { !$0.isRunning }, .start) } }.buttonStyle(RowButton())
                    }
                    if !running.isEmpty {
                        Button("Stop all") { Task { await engine.containerAction(running, .stop) } }.buttonStyle(RowButton())
                    }
                }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .frame(width: Column.actions)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(isHovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
        .animation(.easeOut(duration: 0.12), value: isCollapsed)
    }
}

struct ContainerRow: View {
    @Environment(Engine.self) private var engine
    let container: Container
    let isNested: Bool
    let isSelected: Bool
    @Binding var inspecting: Inspection?
    @State private var isHovered = false

    var body: some View {
        let usage = container.isRunning ? engine.usage[container.Id] : nil
        let busy = engine.busy[container.Id]
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                if isNested {
                    // A tree line from the project's icon, so members read as inside it.
                    Rectangle().fill(Theme.dim.opacity(0.6)).frame(width: 1, height: 40).padding(.leading, 13).padding(.trailing, 8)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.cargoColor(for: container.name).opacity(container.isRunning ? 1 : 0.3))
                    .frame(width: 4, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(container.Image).font(.system(size: 11.5)).foregroundStyle(Theme.soft).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let busy {
                    ProgressView().controlSize(.mini)
                    Text(busy.progress).foregroundStyle(Theme.buoy)
                } else {
                    Circle().fill(container.isRunning ? Theme.ok : Theme.dim).frame(width: 7, height: 7)
                    Text(container.shortStatus).foregroundStyle(container.isRunning ? Theme.text : Theme.soft)
                }
            }
            .lineLimit(1)
            .frame(width: Column.status, alignment: .leading)
            .help(container.Status)
            PortLinks(container: container).frame(width: Column.ports, alignment: .leading)
            Text(usage.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "")
                .frame(width: Column.cpu, alignment: .trailing)
            Text(usage.map { Bytes.small($0.memoryBytes) } ?? "")
                .frame(width: Column.memory, alignment: .trailing)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                let isShowingActions = (isHovered || isSelected) && busy == nil
                Group {
                    Button("Logs") { inspecting = Inspection(container: container, tab: .logs) }.buttonStyle(RowButton())
                    if container.isRunning {
                        Button("Stop") { Task { await engine.containerAction([container], .stop) } }.buttonStyle(RowButton())
                    } else {
                        Button("Start") { Task { await engine.containerAction([container], .start) } }.buttonStyle(RowButton(isPrimary: true))
                    }
                }
                .opacity(isShowingActions ? 1 : 0)
                .allowsHitTesting(isShowingActions)
            }
            .frame(width: Column.actions)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.selection : isHovered ? Theme.hover : .clear)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? Theme.selectionEdge : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .opacity(busy == .remove ? 0.4 : 1)
    }
}

private struct PortLinks: View {
    @Environment(Engine.self) private var engine
    let container: Container

    var body: some View {
        let ports = container.publishedPorts
        HStack(spacing: 4) {
            if let p = ports.first {
                let url = p.localURL
                Button { engine.open(url) } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: "localhost:\(p.PublicPort ?? 0)")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).opacity(container.isRunning ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(container.isRunning ? Theme.text : Theme.dim)
                .disabled(!container.isRunning)
                .help(container.isRunning ? "Open \(url.absoluteString), port \(p.PrivatePort) in the container" : "Start the container to open this port")
            }
            if ports.count > 1 {
                Text("+\(ports.count - 1)").foregroundStyle(Theme.soft)
                    .help(ports.dropFirst().compactMap { $0.PublicPort.map { "localhost:\($0)" } }.joined(separator: "\n"))
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
    }
}

/// An empty list explains itself, and gives the command to fill it with a copy button.
struct EmptyState: View {
    let title: String
    let detail: String
    let command: String?
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.soft)
            if let command {
                HStack(spacing: 10) {
                    Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button(isCopied ? "Copied" : "Copy") {
                        copy(command)
                        isCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            isCopied = false
                        }
                    }
                    .buttonStyle(RowButton())
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small labelled button for list rows, so actions read as words instead of guessable icons.
struct RowButton: ButtonStyle {
    var isPrimary = false
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((isPrimary ? Theme.text : Theme.raised).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .foregroundStyle(isPrimary ? Theme.night : isDestructive ? Theme.danger : Theme.text)
            .opacity(isEnabled ? 1 : 0.4)
            .fixedSize()
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.soft)
            if let isFocused {
                TextField(prompt, text: $text).textFieldStyle(.plain).focused(isFocused).onExitCommand { text = "" }
                Text("⌘F").font(.system(size: 11)).foregroundStyle(Theme.dim).opacity(text.isEmpty ? 1 : 0)
            } else {
                TextField(prompt, text: $text).textFieldStyle(.plain)
            }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.soft)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}


struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        // Newest reading sits at the right edge, so a short history grows in from the right.
        let start = 60 - values.count
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", start + i), y: .value("v", v)).foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("t", start + i), y: .value("v", v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.3))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...59)
        .chartYScale(domain: 0...max(1, (values.max() ?? 1) * 1.3))
    }
}

/// Start, stop, restart and remove where the user is already looking, so the sheet is not a dead end.
private struct SheetActions: View {
    @Environment(Engine.self) private var engine
    let container: Container
    let onRemoved: () -> Void
    @State private var isConfirmingRemove = false

    var body: some View {
        let busy = engine.busy[container.Id]
        HStack(spacing: 6) {
            if let busy {
                ProgressView().controlSize(.mini)
                Text(busy.progress).font(.system(size: 12)).foregroundStyle(Theme.buoy)
            } else if container.isRunning {
                Button("Stop") { Task { await engine.containerAction([container], .stop) } }.buttonStyle(RowButton())
                Button("Restart") { Task { await engine.containerAction([container], .restart) } }.buttonStyle(RowButton())
            } else {
                Button("Start") { Task { await engine.containerAction([container], .start) } }.buttonStyle(RowButton(isPrimary: true))
            }
            Button("Remove…") { isConfirmingRemove = true }.buttonStyle(RowButton(isDestructive: true)).disabled(busy != nil)
        }
        .confirmationDialog("Remove \(container.name)?", isPresented: $isConfirmingRemove) {
            Button("Remove container", role: .destructive) {
                onRemoved()
                Task { await engine.containerAction([container], .remove) }
            }
        } message: {
            Text(container.isRunning ? "It is running and will be stopped first. Its volumes are kept." : "Its volumes are kept.")
        }
    }
}

struct ContainerSheet: View {
    @Environment(Engine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let container: Container
    @State var tab: DetailTab
    @State private var detail: ContainerDetail?
    @State private var detailError: String?
    @State private var logs = ""
    @State private var logsError: String?
    @State private var isFollowingLogs = true
    @State private var isShowingEnvValues = false

    /// The row as Docker reports it now, so status and stats follow starts and stops made elsewhere.
    private var live: Container { engine.containers.first { $0.Id == container.Id } ?? container }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CargoBox(name: live.shortName, colorKey: live.name).frame(width: 78, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(live.name).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(live.isRunning ? Theme.ok : Theme.dim).frame(width: 7, height: 7)
                        Text(live.shortStatus).foregroundStyle(live.isRunning ? Theme.text : Theme.soft)
                        Text(live.Image).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.soft)
                    }
                    .font(.system(size: 11.5))
                }
                Spacer()
                SheetActions(container: live) { dismiss() }
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider().overlay(Theme.line)
            switch tab {
            case .overview: overview
            case .logs: logView
            }
        }
        .frame(width: 820, height: 580)
        .background(Theme.night)
        .preferredColorScheme(.dark)
        .task(id: live.Status) { await loadDetail() }
    }

    private func loadDetail() async {
        guard engine.phase == .running else { return }
        do {
            detail = try await engine.detail(for: live)
            detailError = nil
        } catch {
            // Keep the last good details on screen and only complain when there is nothing to show.
            if detail == nil { detailError = "Crateyard could not read this container's details. \(error.localizedDescription)" }
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let u = engine.usage[live.Id], live.isRunning {
                    HStack(spacing: 28) {
                        BigStat(label: "CPU", value: String(format: "%.1f%%", u.cpuPercent))
                        BigStat(label: "Memory", value: Bytes.small(u.memoryBytes))
                        BigStat(label: "Network in", value: Bytes.small(u.rxBytes))
                        BigStat(label: "Network out", value: Bytes.small(u.txBytes))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CPU, LAST 2 MINUTES").font(.system(size: 10.5, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(Theme.dim)
                        Sparkline(values: u.cpuHistory, color: Theme.cargoColor(for: live.name)).frame(height: 56)
                    }
                }
                if let d = detail {
                    DetailSection("Run") {
                        Row("Command", d.command.isEmpty ? "image default" : d.command, mono: true)
                        if let wd = d.Config.WorkingDir, !wd.isEmpty { Row("Working dir", wd, mono: true) }
                        Row("Status", live.Status)
                        if let started = d.startedAt { Row("Started", started.formatted(.relative(presentation: .named))) }
                        let restarts = d.RestartCount ?? 0
                        Row("Restart policy", d.restartPolicy + (restarts > 0 ? ", restarted \(restarts) times" : ""))
                    }
                    if !live.publishedPorts.isEmpty {
                        DetailSection("Ports") {
                            ForEach(live.publishedPorts, id: \.self) { p in
                                Button { engine.open(p.localURL) } label: {
                                    Row("localhost:\(p.PublicPort ?? 0)", "container port \(p.PrivatePort)", mono: true, link: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !d.networks.isEmpty {
                        DetailSection("Networks") {
                            ForEach(d.networks, id: \.name) { n in Row(n.name, n.ip.isEmpty ? "no address" : n.ip, mono: true) }
                        }
                    }
                    if let mounts = d.Mounts, !mounts.isEmpty {
                        DetailSection("Mounts") {
                            ForEach(mounts, id: \.self) { m in
                                Row(m.Destination, "\(m.Type == "volume" ? "volume" : m.Source ?? "")\(m.RW == false ? ", read only" : "")", mono: true)
                            }
                        }
                    }
                    if let env = d.Config.Env, !env.isEmpty {
                        DetailSection("Environment") {
                            Toggle("Show values", isOn: $isShowingEnvValues)
                                .toggleStyle(.switch).controlSize(.mini)
                                .font(.system(size: 11.5)).foregroundStyle(Theme.soft)
                            ForEach(Array(env.enumerated()), id: \.offset) { _, pair in
                                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                                // Values often hold passwords, so they stay hidden until asked for.
                                Row(parts.first ?? pair, isShowingEnvValues ? (parts.count > 1 ? parts[1] : "") : "••••••", mono: true)
                            }
                        }
                    }
                } else if let detailError {
                    Text(detailError).font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logView: some View {
        VStack(spacing: 0) {
            HStack {
                if let logsError { Text(logsError).font(.system(size: 11.5)).foregroundStyle(Theme.danger).lineLimit(2) }
                Spacer()
                Toggle("Follow", isOn: $isFollowingLogs)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.soft)
                    .help("Keep the newest lines in view. Turn off to read earlier output.")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider().overlay(Theme.line)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logs.isEmpty ? "No output yet." : logs)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .id("end")
                }
                .onChange(of: logs) { if isFollowingLogs { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .task {
            while !Task.isCancelled {
                if engine.phase == .running {
                    do {
                        logs = try await engine.logs(for: live)
                        logsError = nil
                    } catch {
                        logsError = "Crateyard could not read new log lines. \(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct BigStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(Theme.dim)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(Theme.soft)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct Row: View {
    let key: String
    let value: String
    let isMono: Bool
    let isLink: Bool

    init(_ key: String, _ value: String, mono: Bool = false, link: Bool = false) {
        self.key = key
        self.value = value
        self.isMono = mono
        self.isLink = link
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key).font(.system(size: 12.5, design: isMono ? .monospaced : .default)).foregroundStyle(isLink ? Theme.text : Theme.soft)
                .frame(width: 220, alignment: .leading).lineLimit(1).truncationMode(.middle)
            Text(value).font(.system(size: 12.5, design: isMono ? .monospaced : .default))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if isLink { Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Theme.soft) }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
