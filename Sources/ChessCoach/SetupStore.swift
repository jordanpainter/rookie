import Foundation

/// The first launch, for somebody who has downloaded Rookie and nothing else.
///
/// The app carries its own Python and Stockfish, so a game of chess works the
/// moment it opens. Three things do not, and all three are downloads: the model
/// Chichi talks through, the named opening list Explore searches, and the
/// puzzles Drill serves. Before this screen existed they were fetched by
/// `setup.sh`, which is fine for the person who wrote the app and useless for
/// anybody else: they would open Rookie, find two empty tabs and a coach that
/// said nothing, with the instructions in a README they never read.
@MainActor
final class SetupStore: ObservableObject {
    enum State: Equatable {
        case checking
        case missing
        case working(String, Double?)   // what it is doing, and how far along
        case ready(String)              // what it found
        case failed(String)
        /// The app could not find out. Never offers a download: the one time
        /// this happened it was a stale daemon answering "unknown op", and the
        /// screen cheerfully offered to fetch 30,000 puzzles already on disk.
        case unsure(String)
    }

    @Published var ollama: State = .checking
    @Published var model: State = .checking
    @Published var openings: State = .checking
    @Published var puzzles: State = .checking
    /// Set once the person has seen the screen and chosen to go in anyway.
    @Published var dismissed = false
    /// False until the first check has finished and the app knows whether there
    /// is anything to show.
    @Published var decided = false

    /// Ollama is installed but not answering, which is a different sentence
    /// from not having it at all.
    @Published var ollamaInstalled = false

    private let endpoint = "http://127.0.0.1:11434"
    private var modelName: String { AppConfig.shared.model }

    var isComplete: Bool {
        if case .ready = ollama, case .ready = model,
           case .ready = openings, case .ready = puzzles { return true }
        return false
    }

    /// Is there anything the app can actually offer to fix? Only a definite
    /// "missing" counts: not knowing is not a reason to show somebody a
    /// checklist, let alone offer them a download they may not need.
    var needsAttention: Bool {
        [ollama, model, openings, puzzles].contains { if case .missing = $0 { return true }; return false }
    }

    /// Everything, in one pass. Cheap: two HTTP calls and one socket call.
    func checkAll() async {
        await checkOllama()
        await checkLibrary()
    }

    func checkOllama() async {
        ollama = .checking
        model = .checking
        ollamaInstalled = ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama",
                           "/usr/local/bin/ollama"].contains {
            FileManager.default.fileExists(atPath: $0)
        }
        guard let tags = await get("/api/tags") else {
            ollama = .missing
            model = .missing
            return
        }
        ollama = .ready("Running")
        let models = (tags["models"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        // Ollama reports "gemma4:12b"; a tag written without one means "latest".
        let wanted = modelName.contains(":") ? modelName : modelName + ":latest"
        model = models.contains(wanted) ? .ready("Installed") : .missing
    }

    func checkLibrary() async {
        openings = .checking
        puzzles = .checking
        guard let data = try? await ChatStore.ask(["op": "library"]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            openings = .unsure("Couldn't reach the engine to check.")
            puzzles = .unsure("Couldn't reach the engine to check.")
            return
        }
        guard object["error"] == nil,
              let namedOpenings = object["openings"] as? Int,
              let lichessPuzzles = object["puzzles"] as? Int else {
            openings = .unsure("Couldn't read what's installed.")
            puzzles = .unsure("Couldn't read what's installed.")
            return
        }
        openings = namedOpenings > 0 ? .ready("\(namedOpenings.formatted()) openings") : .missing
        puzzles = lichessPuzzles > 0 ? .ready("\(lichessPuzzles.formatted()) puzzles") : .missing
    }

    /// Pulls the model through Ollama's own API, so the progress bar is the
    /// real download rather than a guess. Ollama streams one JSON object per
    /// line, each with how many bytes are done.
    func pullModel() async {
        model = .working("Starting the download", nil)
        guard let url = URL(string: endpoint + "/api/pull") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelName,
                                                                       "stream": true])
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                model = .failed("Ollama refused the download.")
                return
            }
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let problem = object["error"] as? String {
                    model = .failed(problem)
                    return
                }
                let status = object["status"] as? String ?? "Downloading"
                let done = object["completed"] as? Double
                let total = object["total"] as? Double
                if let done, let total, total > 0 {
                    model = .working("\(bytes: done) of \(bytes: total)", done / total)
                } else {
                    model = .working(status.capitalizedFirst, nil)
                }
            }
            await checkOllama()
        } catch {
            model = .failed(error.localizedDescription)
        }
    }

    /// Nothing here can run without the Python half, and "the download failed"
    /// is the wrong thing to say when the interpreter is missing: that happens
    /// when the app is run from source without `setup.sh` having made a venv,
    /// and no amount of retrying fixes it.
    private var missingPython: String? {
        FileManager.default.isExecutableFile(atPath: Paths.python) ? nil
            : "Rookie can't find its Python at \(Paths.python). A downloaded Rookie.app "
                + "carries its own; from source, run ./setup.sh once."
    }

    func importOpenings() async {
        if let problem = missingPython { openings = .failed(problem); return }
        openings = .working("Fetching the opening list", nil)
        let ok = await runPython(Paths.openings, ["import"]) { _ in }
        if ok { await checkLibrary() } else { openings = .failed("The download failed.") }
    }

    /// The Lichess puzzle dump is streamed and filtered rather than saved: it is
    /// several hundred megabytes and only the band around the player's rating is
    /// wanted. Without a linked account that band is a beginner's, and Settings
    /// re-imports once an account says otherwise.
    func importPuzzles() async {
        if let problem = missingPython { puzzles = .failed(problem); return }
        puzzles = .working("Streaming the puzzle set", nil)
        let ok = await runPython(Paths.puzzles, ["import"]) { line in
            // "  kept 12000 of 340000 scanned"
            guard line.contains("kept") else { return }
            Task { @MainActor in
                self.puzzles = .working(line.trimmingCharacters(in: .whitespaces), nil)
            }
        }
        if ok { await checkLibrary() } else { puzzles = .failed("The download failed.") }
    }

    // MARK: - plumbing

    private func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: endpoint + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func runPython(_ script: String, _ arguments: [String],
                           onLine: @escaping @Sendable (String) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Paths.python)
                process.arguments = [script] + arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = String(decoding: handle.availableData, as: UTF8.self)
                    for line in chunk.split(separator: "\n") { onLine(String(line)) }
                }
                do {
                    try process.run()
                    process.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

private extension String.StringInterpolation {
    /// "4.1 GB", the way a download should read.
    mutating func appendInterpolation(bytes value: Double) {
        appendLiteral(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))
    }
}
