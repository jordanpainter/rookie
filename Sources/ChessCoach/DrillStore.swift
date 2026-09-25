import Foundation

struct Puzzle: Decodable, Equatable {
    let id: String
    let source: String
    let positionFen: String
    let turn: String
    let rating: Int?
    let themes: String?
    /// For your own blunders: the move you actually played at the time.
    let playedSan: String?
    let opponentMove: String?
    /// Supplied by the engine. Without it the board will not accept a tap.
    let legal: [String: [String]]?

    enum CodingKeys: String, CodingKey {
        case id, source, turn, rating, themes, legal
        case positionFen = "position_fen"
        case playedSan = "played_san"
        case opponentMove = "opponent_move"
    }

    var isOwn: Bool { source == "own" }
}

struct PuzzleResult: Decodable, Equatable {
    let correct: Bool
    /// Right, but not the stored answer: Stockfish rated it within half a pawn.
    let alsoGood: Bool?
    let answerSan: String?
    let yourMoveSan: String?
    let playedBefore: String?

    enum CodingKeys: String, CodingKey {
        case correct
        case alsoGood = "also_good"
        case answerSan = "answer_san"
        case yourMoveSan = "your_move_san"
        case playedBefore = "played_before"
    }
}

struct DrillStats: Decodable {
    struct Day: Decodable {
        let solved: Int
        let attempted: Int
    }

    let total: Int
    let attempted: Int
    let solved: Int
    let failed: Int
    let dueNow: Int
    /// Keyed by drill source: today only, so a puzzle failed on Tuesday is not
    /// still being reported on Friday.
    let today: [String: Day]

    enum CodingKeys: String, CodingKey {
        case total, attempted, solved, failed, today
        case dueNow = "due_now"
    }
}

/// The three kinds of drill. Endgames are a different shape from the other two:
/// a multi-move drill against perfect defence rather than a single answer.
enum DrillSource: String, CaseIterable, Identifiable {
    case own = "Your blunders"
    case lichess = "Lichess"
    case endgame = "Endgames"

    var id: String { rawValue }
    /// The name this source has in the database and in the day's tally.
    var wire: String {
        switch self {
        case .own:     return "own"
        case .lichess: return "lichess"
        case .endgame: return "endgame"
        }
    }
    var isPuzzle: Bool { self != .endgame }
}

@MainActor
final class DrillStore: ObservableObject {
    @Published var puzzle: Puzzle?
    @Published var result: PuzzleResult?
    @Published var stats: DrillStats?
    @Published var source: DrillSource = .own
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var hasLoaded = false

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        next()
    }

    func next() {
        result = nil
        request(["op": "puzzle_next", "source": source.wire]) { data in
            self.puzzle = try? JSONDecoder().decode(Puzzle.self, from: data)
            // Empty means two different things for your own blunders: none due
            // today, or never linked an account, which is every new user. Only
            // the second is fixable, so say how.
            if self.puzzle == nil {
                self.errorMessage = self.source == .own
                    ? "No blunder puzzles due. They're built from your chess.com games, so link your account in Review if you haven't."
                    : "No puzzles left in that set."
            }
        }
        refreshStats()
    }

    /// One attempt per puzzle. The answer is only revealed once you have tried,
    /// so there is no way to read it off the wire first.
    func attempt(from: String, to: String) {
        guard let puzzle, result == nil else { return }
        request(["op": "puzzle_try", "id": puzzle.id, "uci": from + to]) { data in
            self.result = try? JSONDecoder().decode(PuzzleResult.self, from: data)
            self.refreshStats()
        }
    }

    /// The day's tally covers every source, including endgames, so it is worth
    /// having even when the endgame tab is the one on screen.
    func refreshStats() {
        request(["op": "puzzle_stats"]) { data in
            self.stats = try? JSONDecoder().decode(DrillStats.self, from: data)
        }
    }

    private func request(_ payload: [String: Any], then handle: @escaping (Data) -> Void) {
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let data = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { c.resume(returning: try CoachClient.send(payload)) }
                        catch { c.resume(throwing: error) }
                    }
                }
                handle(data)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
