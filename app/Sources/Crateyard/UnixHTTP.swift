import Foundation

enum UnixHTTPError: LocalizedError {
    case socketPathTooLong(String)
    case connect(String, Int32)
    case io(Int32)
    case timedOut(TimeInterval)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path): return "The socket path \(path) is longer than macOS allows. Move Crateyard's folder to a shorter path."
        case .connect(let path, let code): return "Could not connect to \(path): \(String(cString: strerror(code))). Check that Crateyard is running."
        case .io(let code): return "The connection failed: \(String(cString: strerror(code))). Try again, or restart Crateyard from the menu bar."
        case .timedOut(let seconds): return "Docker did not answer within \(Int(seconds.rounded(.up))) seconds. Check that Crateyard is running, or restart it from the menu bar."
        case .badResponse: return "The engine sent a response Crateyard could not read. Restart Crateyard from the menu bar."
        }
    }

    /// True when nothing is listening: the engine is stopped, not merely slow.
    var isNotListening: Bool {
        if case .connect(_, let code) = self { return code == ENOENT || code == ECONNREFUSED }
        return false
    }
}

struct HTTPResponse {
    let status: Int
    let body: Data

    var isSuccess: Bool { (200..<300).contains(status) }
}

/// A minimal HTTP/1.1 client over a Unix domain socket, for crateyardd's control socket and the Docker API.
/// URLSession cannot dial Unix sockets, so each request opens a socket, sends one request and reads the response.
struct UnixHTTP: Sendable {
    let socketPath: String

    /// Socket calls block, so they run here instead of tying up Swift's cooperative thread pool.
    private static let queue = DispatchQueue(label: "crateyard.unixhttp", qos: .userInitiated, attributes: .concurrent)

    func get(_ target: String, timeout: TimeInterval = 10) async throws -> HTTPResponse {
        try await send("GET", target, body: nil, timeout: timeout)
    }

    func send(_ method: String, _ target: String, body: Data? = nil, timeout: TimeInterval = 30) async throws -> HTTPResponse {
        let path = socketPath
        return try await withCheckedThrowingContinuation { done in
            UnixHTTP.queue.async {
                done.resume(with: Result { try UnixHTTP.perform(path: path, method: method, target: target, body: body, timeout: timeout) })
            }
        }
    }

    private static func perform(path: String, method: String, target: String, body: Data?, timeout: TimeInterval) throws -> HTTPResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixHTTPError.io(errno) }
        defer { close(fd) }
        // A peer that closes mid-write would otherwise kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw UnixHTTPError.socketPathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw UnixHTTPError.connect(path, errno) }

        let whole = timeout.rounded(.down)
        var tv = timeval(tv_sec: Int(whole), tv_usec: Int32((timeout - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var head = "\(method) \(target) HTTP/1.1\r\nHost: crateyard\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method != "GET" {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }
        try writeAll(fd, request, timeout: timeout)

        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var expected: Int?
        while expected.map({ raw.count < $0 }) ?? true {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                // SO_RCVTIMEO expiry surfaces as EAGAIN.
                if errno == EAGAIN || errno == EWOULDBLOCK { throw UnixHTTPError.timedOut(timeout) }
                throw UnixHTTPError.io(errno)
            }
            raw.append(buffer, count: n)
            if expected == nil { expected = expectedLength(raw) }
        }
        if let expected, raw.count < expected { throw UnixHTTPError.badResponse }
        return try parse(raw)
    }

    /// The total response size when the headers carry Content-Length, so reading can stop without waiting for close.
    private static func expectedLength(_ raw: Data) -> Int? {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[raw.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length", let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return split.upperBound - raw.startIndex + n
            }
        }
        return nil
    }

    private static func writeAll(_ fd: Int32, _ data: Data, timeout: TimeInterval) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw UnixHTTPError.timedOut(timeout) }
                    throw UnixHTTPError.io(errno)
                }
                offset += n
            }
        }
    }

    static func parse(_ raw: Data) throws -> HTTPResponse {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { throw UnixHTTPError.badResponse }
        guard let head = String(data: raw[raw.startIndex..<split.lowerBound], encoding: .utf8) else { throw UnixHTTPError.badResponse }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { throw UnixHTTPError.badResponse }
        let isChunked = lines.dropFirst().contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        let body = Data(raw[split.upperBound...])
        return HTTPResponse(status: status, body: isChunked ? try dechunk(body) : body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var index = data.startIndex
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { throw UnixHTTPError.badResponse }
            let sizeText = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii)?.split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw UnixHTTPError.badResponse }
            if size == 0 { return out }
            let start = lineEnd.upperBound
            guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) else { throw UnixHTTPError.badResponse }
            out.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        // A chunked body that ends without its zero-size chunk was cut off.
        throw UnixHTTPError.badResponse
    }
}
