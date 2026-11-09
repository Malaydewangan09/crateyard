import Foundation

enum EngineState: String, Decodable {
    case starting, running, stopping, sleeping
}

/// crateyardd's view of the engine. Memory is what macOS charges for the VM, never the balloon target.
struct EngineStatus: Decodable {
    let state: EngineState
    let bootSeconds: Double
    let vmFootprintBytes: UInt64
    let guestUsedBytes: UInt64
    let memoryLimitBytes: UInt64
    let dataDiskBytes: UInt64
    /// When the VM sleeps if nothing starts first. nil while containers run or a client is busy.
    let sleepsAt: Date?
    /// Why the last wake failed, if it did.
    let lastError: String?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Plain .iso8601 has no fractional seconds, which works because crateyardd sends whole seconds.
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum ContainerAction {
    case start, stop, restart, remove

    /// Shown on the row while Docker works on it.
    var progress: String {
        switch self {
        case .start: return "Starting…"
        case .stop: return "Stopping…"
        case .restart: return "Restarting…"
        case .remove: return "Removing…"
        }
    }

    func request(for id: String) -> (method: String, target: String) {
        switch self {
        case .start: return ("POST", "/containers/\(id)/start")
        case .stop: return ("POST", "/containers/\(id)/stop")
        case .restart: return ("POST", "/containers/\(id)/restart")
        case .remove: return ("DELETE", "/containers/\(id)?force=1")
        }
    }
}

struct PortBinding: Decodable, Hashable {
    let PrivatePort: Int
    let PublicPort: Int?
    let `Type`: String

    /// The address to open on the Mac. Only meaningful for bindings from Container.publishedPorts.
    var localURL: URL { URL(string: "http://localhost:\(PublicPort ?? PrivatePort)")! }
}

struct ContainerMount: Decodable, Hashable {
    let `Type`: String
    let Name: String?
}

struct Container: Decodable, Identifiable, Hashable {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let Mounts: [ContainerMount]?
    let State: String
    let Status: String
    let Ports: [PortBinding]?
    let Labels: [String: String]?

    var id: String { Id }
    var composeProject: String? { Labels?["com.docker.compose.project"] }
    /// The short name for tight spaces: the Compose service when there is one, else the container name.
    var shortName: String { Labels?["com.docker.compose.service"] ?? name }
    var name: String { Names.first.map { String($0.drop(while: { $0 == "/" })) } ?? String(Id.prefix(12)) }
    var isRunning: Bool { State == "running" }
    /// Docker's status without the exit code, e.g. "Exited 6 hours ago". The full text goes in the tooltip.
    var shortStatus: String {
        guard Status.hasPrefix("Exited ("), let close = Status.firstIndex(of: ")") else { return Status }
        return "Exited" + Status[Status.index(after: close)...]
    }
    var volumeNames: [String] { (Mounts ?? []).filter { $0.`Type` == "volume" }.compactMap(\.Name) }
    var publishedPorts: [PortBinding] {
        var seen = Set<Int>()
        return (Ports ?? []).filter { $0.PublicPort != nil && $0.`Type` == "tcp" && seen.insert($0.PublicPort!).inserted }
            .sorted { ($0.PublicPort ?? 0) < ($1.PublicPort ?? 0) }
    }
}

struct DockerImage: Decodable, Identifiable, Hashable {
    let Id: String
    let RepoTags: [String]?
    let Size: Int64
    let Created: Int64
    /// -1 when Docker did not count, which only /system/df does.
    let Containers: Int?

    var id: String { Id }
    var name: String {
        if let tag = RepoTags?.first, tag != "<none>:<none>" { return tag }
        return String(Id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }
    var isInUse: Bool { (Containers ?? 0) > 0 }
    var created: Date { Date(timeIntervalSince1970: TimeInterval(Created)) }
}

struct DockerVolume: Decodable, Identifiable, Hashable {
    struct Usage: Decodable, Hashable {
        let Size: Int64
        let RefCount: Int
    }

    let Name: String
    let UsageData: Usage?

    var id: String { Name }
    /// Docker names volumes created without a name with a 64-character hex id.
    var isAnonymous: Bool { Name.count == 64 && Name.allSatisfy(\.isHexDigit) }
}

struct DiskUsage: Decodable {
    let Images: [DockerImage]?
    let Volumes: [DockerVolume]?
}

/// One reading from /containers/{id}/stats. CPU needs two readings, so the Engine keeps the previous one.
struct StatsSample: Decodable {
    struct CPUUsage: Decodable { let total_usage: UInt64 }
    struct CPU: Decodable {
        let cpu_usage: CPUUsage
        let system_cpu_usage: UInt64?
        let online_cpus: Int?
    }
    struct Memory: Decodable {
        let usage: UInt64?
        let stats: [String: UInt64]?
    }
    struct Network: Decodable {
        let rx_bytes: UInt64
        let tx_bytes: UInt64
    }

    let cpu_stats: CPU
    let memory_stats: Memory
    let networks: [String: Network]?

    /// Matches `docker stats`: usage minus reclaimable page cache (inactive_file on cgroup v2).
    var memoryUsed: UInt64 {
        let usage = memory_stats.usage ?? 0
        let cache = memory_stats.stats?["inactive_file"] ?? 0
        return usage > cache ? usage - cache : usage
    }
}

struct ContainerUsage {
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0
    /// CPU percent per poll, oldest first, at most 60 readings (two minutes).
    var cpuHistory: [Double] = []
}

/// The parts of /containers/{id}/json the detail view shows.
struct ContainerDetail: Decodable {
    struct RunConfig: Decodable {
        let Env: [String]?
        let Cmd: [String]?
        let Entrypoint: [String]?
        let WorkingDir: String?
    }
    struct Mount: Decodable, Hashable {
        let `Type`: String?
        let Source: String?
        let Destination: String
        let RW: Bool?
    }
    struct Restart: Decodable { let Name: String? }
    struct Host: Decodable { let RestartPolicy: Restart? }
    struct RunState: Decodable { let StartedAt: String? }
    struct Endpoint: Decodable { let IPAddress: String? }
    struct Net: Decodable { let Networks: [String: Endpoint]? }

    let RestartCount: Int?
    let Config: RunConfig
    let Mounts: [Mount]?
    let HostConfig: Host?
    let State: RunState?
    let NetworkSettings: Net?

    var command: String { ((Config.Entrypoint ?? []) + (Config.Cmd ?? [])).joined(separator: " ") }
    var restartPolicy: String {
        let name = HostConfig?.RestartPolicy?.Name ?? ""
        return name.isEmpty ? "no" : name
    }
    var networks: [(name: String, ip: String)] {
        (NetworkSettings?.Networks ?? [:]).map { ($0.key, $0.value.IPAddress ?? "") }.sorted { $0.name < $1.name }
    }
    var startedAt: Date? { State?.StartedAt.flatMap(Self.date) }

    private static let isoFormatter = ISO8601DateFormatter()

    /// Docker timestamps carry nanoseconds, which ISO8601DateFormatter rejects, so parse to the second.
    static func date(_ s: String) -> Date? {
        guard s.count >= 19, !s.hasPrefix("0001") else { return nil }
        return isoFormatter.date(from: String(s.prefix(19)) + "Z")
    }
}

enum Bytes {
    static func memory(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
    static func small(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }
    static func disk(_ b: Int64) -> String { diskFormatter.string(fromByteCount: b) }

    private static let diskFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        // Without this an empty volume reads "Zero KB" next to "89 bytes".
        f.allowsNonnumericFormatting = false
        return f
    }()
}

/// Splits Docker's multiplexed log stream (8-byte frame headers) into text. A container with a TTY sends raw text instead.
enum DockerLogs {
    static func decode(_ data: Data) -> String {
        guard let first = data.first, first <= 2, data.count >= 8 else { return String(decoding: data, as: UTF8.self) }
        var out = Data()
        var i = data.startIndex
        while i + 8 <= data.endIndex {
            let size = data[(i + 4)..<(i + 8)].reduce(0) { $0 << 8 | Int($1) }
            let start = i + 8
            let end = min(start + size, data.endIndex)
            out.append(data[start..<end])
            i = end
        }
        return String(decoding: out, as: UTF8.self)
    }
}
