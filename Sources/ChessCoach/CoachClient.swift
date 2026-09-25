import Darwin
import Foundation

/// Where the moving parts live.
///
/// The data folder resolves exactly as `coachd/paths.py` does, in the same
/// order: `ROOKIE_HOME`, then a `data_dir` named in the default folder's
/// `config.json`, then `~/Library/Application Support/Rookie`. The middle one
/// exists so an install can keep its data somewhere else without moving the
/// app. Change one side, change both.
enum Paths {
    static let runtimeDir: String = {
        if let forced = ProcessInfo.processInfo.environment["ROOKIE_HOME"], !forced.isEmpty {
            return (forced as NSString).expandingTildeInPath
        }
        let base = ("~/Library/Application Support/Rookie" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: base + "/config.json"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pointed = object["data_dir"] as? String, !pointed.isEmpty {
            return (pointed as NSString).expandingTildeInPath
        }
        return base
    }()
    static let socket = runtimeDir + "/coachd.sock"
    /// Rookie.app carries its own; built from source, `setup.sh` makes a venv in
    /// the data folder.
    static let python: String = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3.14").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return runtimeDir + "/venv/bin/python3"
    }()

    /// The Python half of the app. Inside a built `.app` it is bundled as a
    /// resource; run from the repo it is found by walking up from the
    /// executable, which sits a few folders down in `.build`.
    static let code: String = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("coachd"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("coachd.py").path) {
            return bundled.path
        }
        var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("coachd")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("coachd.py").path) {
                return candidate.path
            }
            dir.deleteLastPathComponent()
        }
        return "coachd"
    }()
    static let coachd = code + "/coachd.py"
    static let history = code + "/history.py"
    static let puzzles = code + "/puzzles.py"
    static let openings = code + "/openings.py"
    /// Where `openings.py` looks for the Lichess token. The data folder, not the
    /// code: it is a credential, and the code folder is inside the app bundle.
    static let lichessToken = runtimeDir + "/lichess-token"
}

enum CoachError: LocalizedError {
    case cannotConnect(String)
    case daemonWontStart
    case badReply(String)

    var errorDescription: String? {
        switch self {
        case .cannotConnect(let why): return "Can't reach the coach engine: \(why)"
        case .daemonWontStart: return "The coach engine wouldn't start. Is Stockfish installed?"
        case .badReply(let raw): return "Unreadable reply from the coach engine: \(raw.prefix(160))"
        }
    }
}

/// Talks to coachd over its Unix socket: one JSON object per line each way,
/// then the connection closes. Starts the daemon if it isn't running, which is
/// also how the app recovers if the daemon dies mid-game.
enum CoachClient {

    /// Returns the raw reply line, for the caller to decode. A failure to
    /// connect means the daemon is down, so start it and try once more.
    /// The blocking call, off the main actor. Every store was writing its own
    /// continuation wrapper around `send`; this is that wrapper, once.
    static func sendAsync(_ payload: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try send(payload))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func send(_ payload: [String: Any]) throws -> Data {
        do {
            return try roundTrip(payload)
        } catch {
            try startDaemon()
            return try roundTrip(payload)
        }
    }

    // MARK: - socket

    private static func roundTrip(_ payload: [String: Any]) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoachError.cannotConnect("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Paths.socket.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw CoachError.cannotConnect("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw CoachError.cannotConnect(String(cString: strerror(errno)))
        }

        var request = try JSONSerialization.data(withJSONObject: payload)
        request.append(0x0A)
        try request.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                guard n > 0 else { throw CoachError.cannotConnect("write failed") }
                sent += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }

        guard !response.isEmpty else { throw CoachError.badReply("<empty>") }
        return response
    }

    // MARK: - lifecycle

    private static let startLock = NSLock()

    /// The newest modification time across this build's Python half, matching
    /// `code_version()` in `coachd.py`.
    private static let codeVersion: Int = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.code)) ?? []
        let newest = files.filter { $0.hasSuffix(".py") }.compactMap { name -> Date? in
            let path = Paths.code + "/" + name
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.map(\.timeIntervalSince1970).max() ?? 0
        return Int(newest)
    }()

    private static var checkedForStaleDaemon = false

    /// A daemon outlives the app that started it, so after an update the new app
    /// finds an old daemon still holding the socket. One did exactly that: it
    /// had never heard of the `library` op, answered with an error, and the
    /// first-launch screen read the error as an empty library and offered to
    /// download 30,000 puzzles that were already on disk. Checked once per
    /// launch, before anything else is asked.
    static func restartIfStale() {
        startLock.lock()
        let alreadyChecked = checkedForStaleDaemon
        checkedForStaleDaemon = true
        startLock.unlock()
        guard !alreadyChecked else { return }

        guard let data = try? roundTrip(["op": "ping"]),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let running = reply["code_version"] as? Int ?? -1
        // No `code_version` at all means a daemon older than this check, which
        // is by definition stale; a different one means a different build.
        guard running != codeVersion else { return }
        _ = try? roundTrip(["op": "shutdown"])
        Thread.sleep(forTimeInterval: 0.3)
        try? startDaemon()
    }

    /// Several requests go out at launch, and each used to find no daemon and
    /// start its own: three were seen at once, each loading two engines before
    /// all but one gave up. One caller starts it; the rest wait on the lock and
    /// then find it already answering.
    private static func startDaemon() throws {
        startLock.lock()
        defer { startLock.unlock() }
        if (try? roundTrip(["op": "ping"])) != nil { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Paths.python)
        process.arguments = [Paths.coachd]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        // Wait for it to answer rather than guessing at a fixed delay.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (try? roundTrip(["op": "ping"])) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CoachError.daemonWontStart
    }
}
