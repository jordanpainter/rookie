import Foundation

struct OpeningStep: Decodable, Equatable {
    let fen: String
    /// Nil on the first entry, which is the starting position.
    let san: String?
    let from: String?
    let to: String?
}

struct BoardStateFile: Decodable {
    let name: String
    let moves: [String]
    let fen: String
    /// Every position the line passes through. Older files have none.
    let steps: [OpeningStep]?
}

/// The starting position — shown until an opening is chosen.
private let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

@MainActor
final class BoardState: ObservableObject {
    @Published var fen: String = startingFEN
    @Published var openingName: String?
    @Published var moves: [String] = []

    /// The line, and where in it we are. An opening is a move order, and a
    /// board showing only the final position has thrown that away: you cannot
    /// tell 1.e4 e5 2.Nf3 from any other route to the same picture.
    @Published var steps: [OpeningStep] = []
    @Published var index: Int = 0
    @Published var isPlaying = false

    private let path = Paths.runtimeDir + "/board-state.json"
    private var watcher: DirectoryWatcher?
    private var playback: Task<Void, Never>?
    /// Whether anything has been read yet. The first read is last session's
    /// leftovers, not a line someone just asked for.
    private var hasLoaded = false

    /// Slow enough to follow, quick enough not to be sat through.
    private static let stepMs = 620

    var canStepBack: Bool { index > 0 }
    var canStepForward: Bool { index + 1 < steps.count }
    var currentMove: MoveHighlight? {
        guard steps.indices.contains(index),
              let from = steps[index].from, let to = steps[index].to else { return nil }
        return MoveHighlight(from: from, to: to)
    }

    func start() {
        reload()
        watcher = DirectoryWatcher(
            path: Paths.runtimeDir
        ) { [weak self] in
            self?.reload()
        }
        watcher?.start()
    }

    func show(_ position: Int) {
        stop()
        guard steps.indices.contains(position) else { return }
        index = position
        fen = steps[position].fen
    }

    func stepForward() { if canStepForward { show(index + 1) } }
    func stepBack() { if canStepBack { show(index - 1) } }

    /// Walk the line from the top. Cancelling is what makes the buttons work
    /// mid-playback rather than fighting it.
    func play() {
        stop()
        guard steps.count > 1 else { return }
        index = 0
        fen = steps[0].fen
        isPlaying = true
        playback = Task { [weak self] in
            guard let self else { return }
            while await self.advance() {
                try? await Task.sleep(for: .milliseconds(Self.stepMs))
                if Task.isCancelled { break }
            }
            await MainActor.run { self.isPlaying = false }
        }
    }

    private func advance() async -> Bool {
        guard canStepForward else { return false }
        index += 1
        fen = steps[index].fen
        return true
    }

    func stop() {
        playback?.cancel()
        playback = nil
        isPlaying = false
    }

    private func reload() {
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(BoardStateFile.self, from: data) else {
            return
        }
        let isNewLine = decoded.name != openingName || decoded.moves != moves
        openingName = decoded.name
        moves = decoded.moves
        steps = decoded.steps ?? []

        // A line that arrives while the app is running plays itself through
        // once. Stepping back to one already on the board should not restart
        // it, and neither should launching: the file still holds whatever was
        // last looked at, and replaying it at startup made the app open by
        // animating an opening nobody had asked for.
        if isNewLine, steps.count > 1 {
            if hasLoaded {
                play()
            } else {
                show(steps.count - 1)
            }
        } else if steps.isEmpty {
            fen = decoded.fen
            index = 0
        }
        hasLoaded = true
    }
}
