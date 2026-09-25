import Foundation

/// The whole-history report, as produced by `history.py report --json`.
/// One shape, rendered here and in the terminal, so the two cannot disagree.
struct HistoryStats: Decodable {
    /// Only present on an update, not on a plain report.
    let imported: Int?
    let games: Int
    let wins: Int
    let draws: Int
    let losses: Int
    let outcomes: [String: Int]
    let movesScored: Int
    let blunders: Int
    let mistakes: Int
    let inaccuracies: Int
    /// Restricted to positions where the game was still genuinely in the
    /// balance. A blunder in an already-lost position teaches much less.
    let competitiveMoves: Int
    let competitiveBlunders: Int
    let clockSummary: ClockSummary
    /// Each value is [moves seen, blunders among them].
    let byPhase: [String: [Int]]
    let byPiece: [String: [Int]]
    let byColour: [String: [Int]]
    let byClock: [String: [Int]]
    let openings: [String: [Opening]]

    struct ClockSummary: Decodable {
        let lowestS: Double?
        let averageS: Double?
        let movesUnder60s: Int

        enum CodingKeys: String, CodingKey {
            case lowestS = "lowest_s"
            case averageS = "average_s"
            case movesUnder60s = "moves_under_60s"
        }
    }

    struct Opening: Decodable, Identifiable {
        let name: String
        let played: Int
        let won: Int
        var id: String { name }
        var winRate: Double { played > 0 ? Double(won) / Double(played) : 0 }
    }

    enum CodingKeys: String, CodingKey {
        case games, wins, draws, losses, outcomes, blunders, mistakes, inaccuracies, openings
        case imported
        case movesScored = "moves_scored"
        case competitiveMoves = "competitive_moves"
        case competitiveBlunders = "competitive_blunders"
        case clockSummary = "clock_summary"
        case byPhase = "by_phase"
        case byPiece = "by_piece"
        case byColour = "by_colour"
        case byClock = "by_clock"
    }

    var winRate: Double { games > 0 ? Double(wins) / Double(games) : 0 }
    /// Rounded, not truncated: the terminal report rounds, and the two views
    /// reading the same data must not print different numbers.
    var movesPerBlunder: Int {
        blunders > 0 ? Int((Double(movesScored) / Double(blunders)).rounded()) : 0
    }
    var competitiveRate: Double {
        competitiveMoves > 0 ? Double(competitiveBlunders) / Double(competitiveMoves) : 0
    }
    /// True when the clock is simply not a factor, which is worth saying
    /// outright rather than showing four near-empty buckets.
    var clockIsFine: Bool {
        Double(clockSummary.movesUnder60s) < 0.01 * Double(max(1, movesScored))
    }
}

/// What account is linked and what the app has derived from its ratings.
/// Produced by `history.py account`, and by `link` when one is set.
struct AccountInfo: Decodable {
    let username: String?
    let ratings: [String: Int]
    let explorerBands: String
    let puzzleBand: [Int]
    let games: Int?
    let ownPuzzles: Int?
    let lichessPuzzles: Int?
    let lichessOutOfBand: Int?
    /// Set by `link` when it replaced a different account.
    let replaced: String?
    let removedGames: Int?
    let removedPuzzles: Int?

    var playRating: Int? { ratings["rapid"] ?? ratings["blitz"] ?? ratings["bullet"] }
    var tactics: Int? { ratings["tactics"] }

    enum CodingKeys: String, CodingKey {
        case username, ratings, games, replaced
        case explorerBands = "explorer_bands"
        case puzzleBand = "puzzle_band"
        case ownPuzzles = "own_puzzles"
        case lichessPuzzles = "lichess_puzzles"
        case lichessOutOfBand = "lichess_out_of_band"
        case removedGames = "removed_games"
        case removedPuzzles = "removed_puzzles"
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published var stats: HistoryStats?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var hasLoaded = false

    /// True while new games are being fetched and evaluated, which is slower
    /// than a plain read and worth saying so.
    @Published var isUpdating = false
    /// How many new games the last update pulled in.
    @Published var imported: Int?
    /// True when there is no chess.com account configured yet, which is the
    /// state everybody but the author starts in.
    @Published var needsUsername = false

    /// How far a long update has got, read from the Python side's own progress
    /// lines. A first link fetches and analyses every game ever played, which
    /// took eight minutes for 282 games behind a spinner that said nothing.
    @Published var progress: UpdateProgress?

    struct UpdateProgress: Equatable {
        enum Stage: Equatable { case fetching, analysing }
        let stage: Stage
        let done: Int
        let total: Int
        let minutesLeft: Int?
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// The linked account, for the settings panel.
    @Published var account: AccountInfo?
    @Published var isLinking = false
    /// What the last link did, kept so the panel can say it out loud rather
    /// than silently deleting someone's games.
    @Published var linkOutcome: String?
    @Published var linkError: String?

    /// Once per launch, and it fetches rather than just reads. The report was
    /// a database read and nothing ever imported, so it sat frozen at whatever
    /// had last been pulled in by hand: nine games behind, in the end.
    func loadIfNeeded() {
        guard !hasLoaded, !isLoading, !isUpdating else { return }
        hasLoaded = true
        refresh()
    }

    /// Fetch, evaluate, report. Analysis is cached, so a run with nothing new
    /// costs a database read; the cost is only ever the games you have played
    /// since last time.
    func refresh() {
        guard !isUpdating else { return }
        isUpdating = true
        isLoading = stats == nil
        errorMessage = nil
        Task {
            defer { isUpdating = false; isLoading = false }
            do {
                defer { progress = nil }
                let data = try await Self.run(["update"]) { line in
                    Task { @MainActor in self.read(line) }
                }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["error"] as? String == "no_username" {
                    needsUsername = true
                    return
                }
                needsUsername = false
                let fresh = try JSONDecoder().decode(HistoryStats.self, from: data)
                stats = fresh
                imported = fresh.imported
            } catch {
                // Fall back to whatever is already in the database rather than
                // showing nothing: a failed fetch should not blank the tab.
                if let data = try? await Self.run(["report", "--json"]),
                   let cached = try? JSONDecoder().decode(HistoryStats.self, from: data) {
                    stats = cached
                    errorMessage = "Showing what is already imported; the update failed."
                } else {
                    errorMessage = "Couldn't load your history: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Kept so existing callers of `reload()` still work.
    func reload() { refresh() }

    func loadAccount() {
        Task {
            guard let data = try? await Self.run(["account"]) else { return }
            account = try? JSONDecoder().decode(AccountInfo.self, from: data)
        }
    }

    /// Point the coach at a chess.com account. Linking a different one takes
    /// the old account's games and blunder puzzles with it, which is why the
    /// outcome is reported rather than assumed.
    func link(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLinking else { return }
        isLinking = true
        linkOutcome = nil
        linkError = nil
        Task {
            defer { isLinking = false }
            guard let data = try? await Self.run(["link", "--username", trimmed]) else {
                linkError = "Couldn't reach chess.com."
                return
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["error"] != nil {
                linkError = "No chess.com account called \"\(trimmed)\"."
                return
            }
            guard let result = try? JSONDecoder().decode(AccountInfo.self, from: data) else {
                linkError = "chess.com sent something unreadable."
                return
            }
            account = result
            needsUsername = false
            if let old = result.replaced {
                linkOutcome = "Replaced \(old): removed \(result.removedGames ?? 0) games "
                    + "and \(result.removedPuzzles ?? 0) blunder puzzles."
            } else {
                linkOutcome = "Linked."
            }
            refresh()
            loadAccount()
        }
    }

    /// "  fetched 12/40 months" and "  1200/7405  18/s  eta 5 min".
    private func read(_ line: String) {
        let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if line.contains("fetched"), numbers.count >= 2 {
            progress = UpdateProgress(stage: .fetching, done: numbers[0], total: numbers[1],
                                      minutesLeft: nil)
        } else if line.contains("eta"), numbers.count >= 4 {
            progress = UpdateProgress(stage: .analysing, done: numbers[0], total: numbers[1],
                                      minutesLeft: numbers[3])
        }
    }

    private static func run(_ arguments: [String],
                            onLine: (@Sendable (String) -> Void)? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Paths.python)
                process.arguments = [Paths.history] + arguments
                let stdout = Pipe()
                process.standardOutput = stdout
                if let onLine {
                    // Progress arrives on stderr, a line at a time, while stdout
                    // is held back for the one JSON reply at the end.
                    let stderr = Pipe()
                    stderr.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = String(decoding: handle.availableData, as: UTF8.self)
                        for line in chunk.split(separator: "\n") { onLine(String(line)) }
                    }
                    process.standardError = stderr
                } else {
                    process.standardError = FileHandle.nullDevice
                }
                do {
                    try process.run()
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
