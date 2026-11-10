import AppKit
import Foundation
import Observation

struct MemorySample: Identifiable {
    let at: Date
    let vm: UInt64
    let guest: UInt64
    let segment: Int
    var id: Date { at }
}

enum EnginePhase: Equatable {
    /// Before the first poll answers, so no Start button shows for an engine that is already running.
    case checking
    case notInstalled
    case installing
    case stopped
    case starting
    case running
    case stopping
    /// The VM is stopped to give memory back. crateyardd still runs, and any docker command wakes it.
    case sleeping
}

/// Owns everything the UI shows: engine status from crateyardd and the containers, images and volumes from Docker.
@MainActor
@Observable
final class Engine {
    private(set) var phase: EnginePhase = .checking
    private(set) var status: EngineStatus?
    private(set) var containers: [Container] = []
    private(set) var images: [DockerImage] = []
    private(set) var volumes: [DockerVolume] = []
    /// Live CPU and memory per running container, keyed by container id.
    private(set) var usage: [String: ContainerUsage] = [:]
    /// Containers Docker is working on, shown on their row until the action finishes.
    private(set) var busy: [String: ContainerAction] = [:]
    private var cpuBaseline: [String: (total: UInt64, system: UInt64)] = [:]
    private(set) var setupLog = ""
    /// Memory samples for the dashboard chart, one per poll, the last 10 minutes.
    private(set) var history: [MemorySample] = []
    var lastError: String?
    /// Set when a background refresh fails, shown quietly in the header instead of an alert.
    private(set) var dockerWarning: String?
    /// Stats and disk usage cost a request per container, so they are fetched only while someone is looking.
    var isWindowVisible = false
    private var diskUsageAt = Date.distantPast
    private var dockerRefresh: Task<Void, Never>?

    let stateDir: URL
    private let control: UnixHTTP
    private let docker: UnixHTTP
    private var isLaunching = false

    init() {
        stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".crateyard")
        control = UnixHTTP(socketPath: stateDir.appendingPathComponent("crateyardd.sock").path)
        docker = UnixHTTP(socketPath: stateDir.appendingPathComponent("docker.sock").path)
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var runningCount: Int { containers.filter(\.isRunning).count }

    var hasDataDisk: Bool { FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("data.img").path) }

    /// root-v2 matches rootMarker in crateyardd. A root disk from an older setup lacks it, so setup runs again and keeps the data disk.
    private var isInstalled: Bool {
        ["Image", "initramfs", "root.img", "data.img", "root-v2"].allSatisfy {
            FileManager.default.fileExists(atPath: stateDir.appendingPathComponent($0).path)
        }
    }

    /// The crateyardd binary shipped inside Crateyard.app, or the repo build when running a debug build from source.
    private func crateyardd() -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "crateyardd") { return bundled }
        #if DEBUG
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../bin/crateyardd").standardized
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        #endif
        lastError = "Crateyard's engine is missing from the app. Download Crateyard again from its releases page."
        return nil
    }

    func refresh() async {
        if phase == .installing { return }
        guard isInstalled else {
            phase = .notInstalled
            return
        }
        do {
            let resp = try await control.get("/status", timeout: 2)
            let st = try EngineStatus.decoder.decode(EngineStatus.self, from: resp.body)
            status = st
            isLaunching = false
            // A gap in readings (engine down, Mac asleep) starts a new line instead of a slope nobody measured.
            let segment = (history.last.map { Date.now.timeIntervalSince($0.at) > 10 ? $0.segment + 1 : $0.segment }) ?? 0
            history.append(MemorySample(at: .now, vm: st.vmFootprintBytes, guest: st.guestUsedBytes, segment: segment))
            if history.count > 300 { history.removeFirst(history.count - 300) }
            switch st.state {
            case .starting: phase = .starting
            case .running: phase = .running
            case .stopping: phase = .stopping
            case .sleeping: phase = .sleeping
            }
            if st.state == .running {
                await refreshDocker(isBackground: true)
            } else {
                // Polling Docker would wake the VM, so the lists stay empty until it runs again.
                setIfChanged(\.containers, [])
                dockerWarning = nil
            }
        } catch let error as UnixHTTPError where error.isNotListening {
            status = nil
            setIfChanged(\.containers, [])
            dockerWarning = nil
            phase = isLaunching ? .starting : .stopped
        } catch {
            // A slow or odd answer from a running crateyardd is not a stopped engine, so the phase stays as it was.
            if phase == .checking { phase = .starting }
        }
    }

    /// Concurrent callers share one refresh, so a poll cannot land after an action's refresh and undo it.
    func refreshDocker(isBackground: Bool = false) async {
        if let running = dockerRefresh {
            await running.value
            if isBackground { return }
        }
        let task = Task { await self.loadDocker(isBackground: isBackground) }
        dockerRefresh = task
        await task.value
        if dockerRefresh == task { dockerRefresh = nil }
    }

    private func loadDocker(isBackground: Bool) async {
        do {
            let list = try await docker.get("/containers/json?all=1")
            let fresh = try JSONDecoder().decode([Container].self, from: list.body)
                .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
            setIfChanged(\.containers, fresh)
            if isWindowVisible { await refreshUsage() }
            // Disk usage is slow with many images and volumes, so the background poll asks every 15 seconds.
            if isWindowVisible && (!isBackground || Date.now.timeIntervalSince(diskUsageAt) > 15) {
                let df = try await docker.get("/system/df?type=image&type=volume", timeout: 30)
                let usage = try JSONDecoder().decode(DiskUsage.self, from: df.body)
                setIfChanged(\.images, (usage.Images ?? []).sorted { $0.Size > $1.Size })
                setIfChanged(\.volumes, (usage.Volumes ?? []).sorted { ($0.UsageData?.Size ?? 0) > ($1.UsageData?.Size ?? 0) })
                diskUsageAt = .now
            }
            dockerWarning = nil
        } catch {
            let message = Engine.describe(error)
            if isBackground { dockerWarning = message } else { lastError = message }
        }
    }

    /// Assigning an equal value still redraws every observer, so unchanged lists are left alone.
    private func setIfChanged<T: Equatable>(_ key: ReferenceWritableKeyPath<Engine, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private static func describe(_ error: Error) -> String {
        if error is DecodingError {
            return "Docker sent data Crateyard could not read. This Docker version may be newer than Crateyard supports, so check for a Crateyard update."
        }
        return error.localizedDescription
    }

    private func refreshUsage() async {
        let running = containers.filter(\.isRunning).map(\.Id)
        let docker = self.docker
        // At most four stats requests in flight: dockerd answers each one slowly, and a burst makes the rest time out.
        let samples = await withTaskGroup(of: (String, StatsSample?).self) { group in
            var pending = running[...]
            var out: [(String, StatsSample?)] = []
            func next() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    guard let resp = try? await docker.get("/containers/\(id)/stats?stream=false&one-shot=true", timeout: 5) else { return (id, nil) }
                    return (id, try? JSONDecoder().decode(StatsSample.self, from: resp.body))
                }
            }
            for _ in 0..<4 { next() }
            for await r in group {
                out.append(r)
                next()
            }
            return out
        }
        var next: [String: ContainerUsage] = [:]
        for (id, sample) in samples {
            guard let sample else { continue }
            let total = sample.cpu_stats.cpu_usage.total_usage
            let system = sample.cpu_stats.system_cpu_usage ?? 0
            var u = usage[id] ?? ContainerUsage()
            if let base = cpuBaseline[id], system > base.system, total >= base.total {
                u.cpuPercent = Double(total - base.total) / Double(system - base.system) * Double(sample.cpu_stats.online_cpus ?? 1) * 100
            }
            cpuBaseline[id] = (total, system)
            u.memoryBytes = sample.memoryUsed
            u.rxBytes = sample.networks?.values.reduce(0) { $0 + $1.rx_bytes } ?? 0
            u.txBytes = sample.networks?.values.reduce(0) { $0 + $1.tx_bytes } ?? 0
            u.cpuHistory.append(u.cpuPercent)
            if u.cpuHistory.count > 60 { u.cpuHistory.removeFirst(u.cpuHistory.count - 60) }
            next[id] = u
        }
        usage = next
        cpuBaseline = cpuBaseline.filter { running.contains($0.key) }
    }

    func detail(for c: Container) async throws -> ContainerDetail {
        let resp = try await docker.get("/containers/\(c.Id)/json")
        guard resp.isSuccess else { throw UnixHTTPError.badResponse }
        return try JSONDecoder().decode(ContainerDetail.self, from: resp.body)
    }

    // MARK: Engine lifecycle

    func start() {
        guard let url = crateyardd() else { return }
        let log = stateDir.appendingPathComponent("crateyardd.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = url
            process.arguments = ["run"]
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { p in
                let code = p.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isLaunching = false
                    if code != 0 { self.lastError = "Crateyard's engine stopped with status \(code). See ~/.crateyard/crateyardd.log for the reason." }
                }
            }
            // crateyardd keeps running after Crateyard.app quits, so closing the window never stops containers.
            try process.run()
            isLaunching = true
            phase = .starting
        } catch {
            lastError = "Crateyard could not start its engine: \(error.localizedDescription)"
        }
    }

    func stop() async {
        phase = .stopping
        await post("/stop", failure: "Crateyard could not be stopped")
    }

    func wake() async { await post("/wake", failure: "Crateyard could not wake the VM") }
    func sleepNow() async { await post("/sleep", failure: "Crateyard could not put the VM to sleep") }

    private func post(_ path: String, failure: String) async {
        do {
            _ = try await control.send("POST", path)
        } catch {
            lastError = "\(failure). \(error.localizedDescription)"
        }
    }

    /// The mirror goes into crateyardd's environment and the setup VM's kernel command line, so only plain http(s) URLs pass.
    static func isValidMirror(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host() != nil else { return false }
        return (scheme == "http" || scheme == "https") && !text.contains(where: { $0.isWhitespace || ";&|$`'\"\\<>".contains($0) })
    }

    /// Builds the VM disks once. It downloads Alpine, so it takes a few minutes on a normal connection.
    func install(mirror: String) async {
        let trimmed = mirror.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && !Engine.isValidMirror(trimmed) {
            lastError = "The mirror must be an http or https address with no spaces, for example https://mirror.leaseweb.com/alpine."
            return
        }
        guard let url = crateyardd() else { return }
        phase = .installing
        setupLog = ""
        let process = Process()
        process.executableURL = url
        process.arguments = ["image"]
        var env = ProcessInfo.processInfo.environment
        if !trimmed.isEmpty { env["CRATEYARD_ALPINE_MIRROR"] = trimmed }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendSetupLog(text) }
        }
        let didRun: Bool = await withCheckedContinuation { done in
            process.terminationHandler = { _ in done.resume(returning: true) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                done.resume(returning: false)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // The last lines are usually the error, and they can still be in the pipe after exit.
        if didRun, let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            appendSetupLog(String(decoding: rest, as: UTF8.self))
        }
        if !didRun {
            lastError = "Crateyard could not run its engine to build the VM. Download Crateyard again from its releases page."
        } else if process.terminationStatus != 0 {
            lastError = "Building the VM failed. The log below shows where. A different Alpine mirror often helps."
        }
        phase = isInstalled ? .stopped : .notInstalled
    }

    private func appendSetupLog(_ text: String) {
        // Download progress uses carriage returns, so keep only the last state of each line and a bounded tail.
        setupLog += text.replacingOccurrences(of: "\r", with: "\n")
        if setupLog.count > 20_000 { setupLog = String(setupLog.suffix(20_000)) }
    }

    // MARK: Docker actions

    /// Runs one action on each container in turn and stops at the first failure.
    func containerAction(_ cs: [Container], _ action: ContainerAction) async {
        for c in cs { busy[c.Id] = action }
        await act {
            var last = HTTPResponse(status: 204, body: Data())
            for c in cs {
                let (method, target) = action.request(for: c.Id)
                last = try await self.docker.send(method, target)
                // 304 means it was already started or stopped, which is what was asked for.
                if last.status == 304 { last = HTTPResponse(status: 204, body: Data()) }
                if !last.isSuccess { break }
            }
            return last
        }
        // Only clear rows still showing this action, so a newer action on the same container keeps its label.
        for c in cs where busy[c.Id] == action { busy[c.Id] = nil }
    }

    func remove(_ image: DockerImage) async {
        await act { try await self.docker.send("DELETE", "/images/\(image.Id)") }
    }

    func remove(_ volume: DockerVolume) async {
        let name = volume.Name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? volume.Name
        await act { try await self.docker.send("DELETE", "/volumes/\(name)") }
    }

    func pruneImages() async {
        let filters = #"{"dangling":["false"]}"#.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        await act { try await self.docker.send("POST", "/images/prune?filters=\(filters)", timeout: 300) }
    }

    func logs(for c: Container) async throws -> String {
        let resp = try await docker.get("/containers/\(c.Id)/logs?stdout=1&stderr=1&tail=400&timestamps=0")
        guard resp.isSuccess else { throw UnixHTTPError.badResponse }
        return DockerLogs.decode(resp.body)
    }

    private struct DockerError: Decodable { let message: String }

    private func act(_ op: @escaping () async throws -> HTTPResponse) async {
        do {
            let resp = try await op()
            if !resp.isSuccess {
                let message = (try? JSONDecoder().decode(DockerError.self, from: resp.body))?.message
                lastError = message.map { "Docker refused: \($0)." } ?? "Docker refused the request with status \(resp.status). Try again, or check the container's logs."
            }
        } catch {
            lastError = Engine.describe(error)
        }
        await refreshDocker()
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
