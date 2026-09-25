import Foundation

struct GameState: Decodable {
    let moves: [String]
    let movesSan: [String]
    let fen: String
    let turn: String
    /// Which side the player has this game. Absent from older replies.
    let myColour: String?
    let status: String
    let level: Int?
    /// Present only on a move reply, and only when the engine answered.
    let afterYourMove: AfterYourMove?
    let jordanPlayed: String?
    let enginePlayed: String?
    /// Set when a pawn reached the last rank and the app still has to say which
    /// piece it becomes. No move has been applied yet in that case.
    let needsPromotion: Bool?
    let from: String?
    let to: String?
    /// from-square -> squares it may legally move to. The engine decides
    /// legality; the board only draws what it is told.
    let legal: [String: [String]]?
    let checkSquare: String?
    let lastMove: LastMoveReply?

    struct LastMoveReply: Decodable {
        let from: String
        let to: String
    }

    /// The board after his move and before the reply.
    struct AfterYourMove: Decodable {
        let fen: String
        let lastMove: LastMoveReply

        enum CodingKeys: String, CodingKey {
            case fen
            case lastMove = "last_move"
        }
    }

    enum CodingKeys: String, CodingKey {
        case moves, fen, turn, status, level, from, to, legal
        case myColour = "my_colour"
        case afterYourMove = "after_your_move"
        case movesSan = "moves_san"
        case jordanPlayed = "jordan_played"
        case enginePlayed = "engine_played"
        case needsPromotion = "needs_promotion"
        case checkSquare = "check_square"
        case lastMove = "last_move"
    }
}

private struct CoachErrorReply: Decodable { let error: String }

/// How loudly the coach speaks. Silent plays a straight game; Nudge adds the
/// blunder guard; Explain and Socratic add Chichi on top of it.
enum CoachingMode: String, CaseIterable, Identifiable {
    /// Nothing unless asked.
    case mute = "Mute"
    /// Chichi writes a line when a move is worth remarking on, and says nothing
    /// otherwise. Never holds the board: his line lands when it lands.
    case notes = "Notes"
    /// Holds the board and asks a question about the move just played.
    case socratic = "Socratic"

    var id: String { rawValue }

    /// Whether the model is involved at all. The blunder guard is deliberately
    /// not on this axis any more: it is the single most useful thing the app
    /// does and it used to switch off whenever you wanted less talking.
    var usesModel: Bool { self != .mute }

    /// Only Socratic makes you wait. A question is worth sitting with; a remark
    /// about a move you have already played is not worth freezing the board for.
    var blocksBoard: Bool { self == .socratic }

    var help: String {
        switch self {
        case .mute:     return "Nothing unless you ask."
        case .notes:    return "Chichi remarks on moves worth remarking on."
        case .socratic: return "Holds the board, then asks you a question."
        }
    }
}

/// A move the guard wants you to look at again before it is played.
struct GuardWarning: Identifiable, Equatable {
    let id = UUID()
    let uci: String
    let san: String
    let headline: String
    let lossCp: Int

    static func == (a: GuardWarning, b: GuardWarning) -> Bool { a.id == b.id }
}

private struct DescribeReply: Decodable {
    let summary: String
    /// Square to piece name, for checking Chichi's answer against the board.
    let squares: [String: String]
    /// Where the pieces were two plies ago.
    let squaresRecent: [String: String]?
    /// Square to the squares that piece can reach.
    let yourMobility: [String: String]?
    /// Every occupied square, and what the piece there attacks.
    let attackMap: [String: String]?
    /// Every check available, exhaustively, so one can't be offered out of thin air.
    let yourChecks: [String]?
    /// Whether the player is in check in the position the packet describes.
    let inCheck: Bool?

    enum CodingKeys: String, CodingKey {
        case summary, squares
        case squaresRecent = "squares_recent"
        case yourMobility = "your_mobility"
        case attackMap = "attack_map"
        case yourChecks = "your_checks"
        case inCheck = "in_check"
    }
}

private struct PreviewReply: Decodable {
    let uci: String
    let san: String
    let lossCp: Int
    let warn: Bool
    let headline: String?
    /// "blunder", "mistake", "inaccuracy", or nil for a move worth playing.
    let severity: String?
    /// The engine's own choice in the position before the move.
    let bestUci: String?
    /// What the move actually does, so a reaction can name the right thing.
    let moveKind: MoveKind?

    struct MoveKind: Decodable {
        let mate: Bool
        let capture: Bool
        let fork: Bool
    }

    enum CodingKeys: String, CodingKey {
        case uci, san, warn, headline, severity
        case lossCp = "loss_cp"
        case bestUci = "best_uci"
        case moveKind = "move_kind"
    }
}

/// Where the book stands in the opening being followed.
private struct OpeningNext: Decodable {
    let following: Bool
    let name: String?
    let nextSan: String?
    let now: String?
    /// Set when the line has been left: who left it, with what, and what the
    /// book wanted instead.
    let divergedBy: String?
    let playedSan: String?
    let bookWanted: String?

    enum CodingKeys: String, CodingKey {
        case following, name, now
        case nextSan = "next_san"
        case divergedBy = "diverged_by"
        case playedSan = "played_san"
        case bookWanted = "book_wanted"
    }
}

/// An opening Jordan has said he wants to play. Held as the family rather than
/// the exact line, because the opponent has a vote: a specific ten-ply line
/// dies the moment the engine answers with something else, whereas the family
/// usually survives and still has a book move to point at.
struct FollowedLine: Equatable {
    let family: String
    let name: String
}

/// A promotion the engine is waiting on. Held until the player picks a piece.
struct PendingPromotion: Equatable {
    let from: String
    let to: String
}

private let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

@MainActor
final class GameStore: ObservableObject {
    @Published var fen: String = startingFEN
    @Published var status: String = "no game yet"
    @Published var movesSan: [String] = []
    @Published var lastEngineMove: String?
    @Published var errorMessage: String?
    @Published var isThinking = false
    @Published var pendingPromotion: PendingPromotion?
    @Published var legal: [String: [String]] = [:]
    @Published var checkSquare: String?
    @Published var lastMove: MoveHighlight?
    @Published var flipped = false
    /// Which side you have in the game on the board, as the daemon reports it.
    /// What the last coaching turn led with, so the next one cannot lead with
    /// it again. Cleared with the game.
    private var lastHeadline: String?
    /// The opening the live game is actually in, as of the last book check.
    /// The book button offered whatever was on the Explore tab, which after a
    /// line died was the line that had just died.
    @Published var openingNow: String?
    @Published var myColour: String = "white"
    /// Which side you asked for: "white", "black" or "random". Only the next
    /// new game reads it, so changing it never disturbs the game in progress.
    @Published var preferredColour: String = "white" {
        didSet { UserDefaults.standard.set(preferredColour, forKey: "preferredColour") }
    }
    @Published var coaching: CoachingMode = .notes {
        didSet { UserDefaults.standard.set(coaching.rawValue, forKey: "coachingMode") }
    }
    /// Its own switch now. Off means nothing stops a move that drops a piece,
    /// which is a real choice and should be a deliberate one.
    @Published var guardEnabled: Bool = true {
        didSet { UserDefaults.standard.set(guardEnabled, forKey: "guardEnabled") }
    }
    @Published var warning: GuardWarning?
    /// Set after a move when the dial wants Chichi to say something.
    @Published var coachingPrompt: String?
    /// The board behind the current coaching prompt, so a question naming a
    /// piece that is not there can be caught before it reaches the panel, and
    /// the board two plies before it, because "you captured their pawn on a4"
    /// describes the position before the capture and is not an invention.
    @Published var coachingSquares: [String: String] = [:]
    @Published var coachingSquaresRecent: [String: String] = [:]
    /// Where each of his pieces can go, so "that piece is blocked" is checkable.
    @Published var coachingMobility: [String: String] = [:]
    /// What each piece attacks, so "defended by the pawn on d4" is checkable.
    @Published var coachingAttackMap: [String: String] = [:]
    /// Every check going, so one that isn't can be caught.
    @Published var coachingChecks: [String] = []
    /// Whether the line being written has to be a question.
    @Published var coachingMustAsk = false
    /// The true one-line summary, shown if the question fails that check.
    @Published var coachingFallback: String = ""
    /// True while Chichi is composing a Socratic question. Moves are refused
    /// until it lands, deliberately.
    @Published var awaitingCoach = false
    /// 1 is weakest, 8 strongest. See LEVELS in coachd.py for what each does.
    @Published var level: Int = 2

    /// The engine's verdict on the move being played, carried from the guard
    /// into the coaching packet. On a quiet move the position facts are empty,
    /// and an empty packet is what taught the model to invent a piece to talk
    /// about. This is always true and always present.
    private var lastVerdict: String?
    /// The word the coaching line opens with, chosen by what the move did and
    /// sent in the packet. Left to the model, only "Nice." and "Whoops." ever
    /// came out, and "Whoops." landed on inaccuracies and once on the best move
    /// in the position.
    private var lastReaction: String?
    /// The opening being steered towards, if any, and the book's next word on
    /// it. Recomputed from the position after every move rather than walked
    /// down a fixed list, so the opponent deviating is handled rather than
    /// silently wrong.
    @Published var following: FollowedLine?
    @Published var bookLine: String?


    /// One line per rung, mirroring `LEVELS` in `coachd.py`.
    ///
    /// Levels 1 to 4 play at the engine's weakest honest setting and throw
    /// something away now and then, which is how a beginner actually loses.
    /// 5 upwards is Stockfish limiting its own strength, which it does properly
    /// above 1320 and cannot do at all below it.
    static func levelBlurb(_ level: Int) -> String {
        switch level {
        case 1: return "blunders often"
        case 2: return "blunders regularly"
        case 3: return "blunders sometimes"
        case 4: return "blunders occasionally"
        case 5: return "steady, about 1320"
        case 6: return "about 1600"
        case 7: return "about 1900"
        default: return "about 2200"
        }
    }

    /// Restores the dial and the guard. Both used to reset on every launch, so
    /// a relaunch quietly turned the coach off without saying so.
    func loadSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "coachingMode"),
           let mode = CoachingMode(rawValue: raw) {
            coaching = mode
        }
        if defaults.object(forKey: "guardEnabled") != nil {
            guardEnabled = defaults.bool(forKey: "guardEnabled")
        }
        if let colour = defaults.string(forKey: "preferredColour") {
            preferredColour = colour
        }
    }

    /// Pick up whatever game the daemon already has, so quitting mid-game and
    /// reopening resumes instead of showing an empty board.
    func loadState() {
        send(["op": "state"])
    }

    /// "Sicilian Defense: Najdorf Variation" -> "Sicilian Defense".
    static func family(_ name: String) -> String {
        name.split(separator: ":").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    func follow(name: String) {
        following = FollowedLine(family: Self.family(name), name: name)
        checkBook()
    }

    func unfollow() {
        following = nil
        bookLine = nil
    }

    /// Where the book stands now. Asks for the named lines that continue from
    /// this exact position and picks the one in the chosen family; if none
    /// does, the line is genuinely over and says so rather than inventing a
    /// continuation.
    private func checkBook() {
        guard let followed = following else { return }
        Task {
            guard let data = try? await Self.request(["op": "opening_next",
                                                      "name": followed.name]),
                  let book = try? JSONDecoder().decode(OpeningNext.self, from: data)
            else { return }

            if book.following, let next = book.nextSan {
                bookLine = "\(followed.family): the book plays \(next) here."
                return
            }

            following = nil
            openingNow = book.now
            if let played = book.playedSan, let wanted = book.bookWanted {
                // Whoever left the book, it is you only if it was your colour.
                // Comparing against white was right for exactly as long as
                // white was the only side you could have.
                let who = book.divergedBy == myColour ? "You played" : "They played"
                let landed = book.now.map { " You are in \($0) now." } ?? ""
                bookLine = "The \(followed.family) wanted \(wanted) there. "
                    + "\(who) \(played), so that line is gone.\(landed)"
            } else {
                bookLine = "That is the end of the book for the \(followed.family)."
            }
        }
    }

    func newGame() {
        unfollow()
        lastHeadline = nil
        openingNow = nil
        send(["op": "new_game", "level": level, "colour": preferredColour])
    }

    func playMove(fromSquare: String, toSquare: String) {
        submit(uci: fromSquare + toSquare)
    }

    /// Judges the move, then plays it unless the guard has something to say.
    ///
    /// The judgement happens whether or not the guard is on, because it is also
    /// where the coaching verdict comes from. It used to be skipped with the
    /// guard off, which left every move unrated: Notes then found nothing worth
    /// remarking on ever, and Socratic was told "not measured". Turning off a
    /// warning should not turn off the coach.
    private func submit(uci: String) {
        guard !awaitingCoach else { return }
        errorMessage = nil
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                let data = try await Self.request(["op": "preview", "uci": uci])
                let preview = try? JSONDecoder().decode(PreviewReply.self, from: data)
                lastVerdict = Self.verdict(preview, played: uci)
                lastReaction = Self.reaction(preview, played: uci, ply: movesSan.count)
                if guardEnabled, let preview, preview.warn, let headline = preview.headline {
                    warning = GuardWarning(uci: preview.uci, san: preview.san,
                                           headline: headline, lossCp: preview.lossCp)
                    return
                }
                // Not worth stopping for, or the move was a promotion the engine
                // still needs a piece for. Either way, play it.
                send(["op": "move", "uci": uci])
            } catch {
                send(["op": "move", "uci": uci])
            }
        }
    }

    /// "I meant it." Plays the move the guard flagged.
    func playAnyway() {
        guard let warned = warning else { return }
        warning = nil
        send(["op": "move", "uci": warned.uci])
    }

    /// "Good spot." Drops the move; nothing was ever played.
    func reconsider() {
        warning = nil
    }

    func completePromotion(piece: String) {
        guard let pending = pendingPromotion else { return }
        pendingPromotion = nil
        submit(uci: pending.from + pending.to + piece)
    }

    func cancelPromotion() {
        pendingPromotion = nil
    }

    /// Undo back to your turn: your move and the engine's reply.
    func takeback() {
        send(["op": "takeback"])
    }

    var canTakeBack: Bool { !movesSan.isEmpty }

    private func send(_ payload: [String: Any]) {
        errorMessage = nil
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                let data = try await Self.request(payload)
                if let state = try? JSONDecoder().decode(GameState.self, from: data) {
                    apply(state)
                } else if let reply = try? JSONDecoder().decode(CoachErrorReply.self, from: data) {
                    errorMessage = reply.error
                } else {
                    errorMessage = "Couldn't read the engine's reply."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Long enough that your move lands and reads as yours, short enough that
    /// nobody is waiting. Both moves used to appear in the same frame.
    private static let replyPauseMs = 420

    private func apply(_ state: GameState) {
        // Show his move on its own, then the answer.
        if let mine = state.afterYourMove, state.enginePlayed != nil {
            fen = mine.fen
            lastMove = MoveHighlight(from: mine.lastMove.from, to: mine.lastMove.to)
            checkSquare = nil
            legal = [:]
            isThinking = true
            Task {
                try? await Task.sleep(for: .milliseconds(Self.replyPauseMs))
                isThinking = false
                applyFully(state)
            }
            return
        }
        applyFully(state)
    }

    private func applyFully(_ state: GameState) {
        // A promotion request is a question, not a move: the board hasn't
        // changed, so leave it alone and ask which piece.
        if state.needsPromotion == true, let from = state.from, let to = state.to {
            pendingPromotion = PendingPromotion(from: from, to: to)
            return
        }
        fen = state.fen
        status = state.status
        movesSan = state.movesSan
        lastEngineMove = state.enginePlayed
        legal = state.legal ?? [:]
        checkSquare = state.checkSquare
        lastMove = state.lastMove.map { MoveHighlight(from: $0.from, to: $0.to) }
        if let level = state.level { self.level = level }
        if let colour = state.myColour, colour != myColour {
            myColour = colour
            // Your own pieces at the bottom. Flip is still yours to press; this
            // only sets which way a new game starts, including a resumed one.
            flipped = colour == "black"
        }

        if following != nil { checkBook() }

        if coaching.usesModel, let played = state.jordanPlayed {
            requestCoaching(played: played, reply: state.enginePlayed)
        }
    }

    /// Hands Chichi the position as facts. He is told what to do with them in
    /// his own instructions, so the prompt stays a data packet rather than a
    /// script the app has to keep in sync.
    private func requestCoaching(played: String, reply: String?) {
        let mode = coaching
        Task {
            guard let data = try? await Self.request(["op": "describe"]),
                  let facts = String(data: data, encoding: .utf8) else { return }
            let described = try? JSONDecoder().decode(DescribeReply.self, from: data)

            // In Notes he speaks only when there is something to remark on.
            // A remark after every move is the same remark after every move,
            // and stops being read by about the tenth.
            if mode == .notes && !worthRemarking {
                lastVerdict = nil
                lastReaction = nil
                return
            }

            // Socratic holds the board, because the question is the point and
            // getting three moves ahead of it wastes it. Notes never holds:
            // the line lands when it lands.
            awaitingCoach = mode.blocksBoard
            coachingSquares = described?.squares ?? [:]
            coachingSquaresRecent = described?.squaresRecent ?? [:]
            coachingMobility = described?.yourMobility ?? [:]
            coachingAttackMap = described?.attackMap ?? [:]
            coachingChecks = described?.yourChecks ?? []
            // "Sweet." above a line about being in check reads as a coach who is
            // not looking. The word is about the move; the check is about now,
            // and now wins.
            if described?.inCheck == true { lastReaction = nil }
            coachingMustAsk = mode == .socratic
            coachingFallback = described?.summary ?? ""
            let (packet, headline) = Facts.forModel(facts, alreadySaid: lastHeadline)
            lastHeadline = headline
            coachingPrompt = """
            [in-play coaching, mode=\(mode.rawValue.lowercased())]
            Played: \(played)
            Reaction to open with: \(lastReaction ?? "none, do not react at all")
            Engine's verdict on it: \(lastVerdict ?? "not measured")
            Opponent replied: \(reply ?? "nothing yet")
            Position facts: \(packet)
            """
            lastVerdict = nil
            lastReaction = nil
        }
    }

    /// Is the move just played worth a sentence?
    ///
    /// Clearly good or clearly bad, and nothing in between: the engine's own
    /// choice, a real error, or a position with mate in it. An inaccuracy is
    /// too common to be worth interrupting for, and "sound but not best"
    /// describes most moves anyone plays.
    private var worthRemarking: Bool {
        if lastReaction == "Hell yeah!" { return true }
        guard let verdict = lastVerdict else { return false }
        return verdict.hasPrefix("the strongest move")
            || verdict.hasPrefix("mistake")
            || verdict.hasPrefix("blunder")
    }

    /// A word about the move, or nothing.
    ///
    /// Chosen by what the move actually did rather than at random, so the word
    /// carries information: "Sweet." means it won something, "Smart." means it
    /// forked, "Clean." and "Nice." mean it was quiet and correct. Only a move
    /// the engine would itself have played earns any of them. A compliment
    /// handed out for anything merely adequate stops being information and
    /// starts being an app being polite, so most moves get nothing at all.
    ///
    /// Where two words fit the same slot they alternate on the move number
    /// rather than being picked at random, so the same game always reads the
    /// same way and a test can check it.
    private static func reaction(_ preview: PreviewReply?, played uci: String,
                                 ply: Int) -> String? {
        guard let preview else { return nil }
        let kind = preview.moveKind
        if kind?.mate == true { return "Hell yeah!" }

        switch preview.severity {
        case nil:
            guard preview.bestUci == uci else { return nil }
            if kind?.fork == true { return "Smart." }
            if kind?.capture == true { return "Sweet." }
            return ply.isMultiple(of: 2) ? "Nice." : "Clean."
        case "inaccuracy":
            return "Hmm."
        case "mistake":
            return ply.isMultiple(of: 2) ? "Whoops." : "Shoot."
        default:
            // A blunder that hands over a whole piece is a different animal
            // from one that drops a pawn's worth of position.
            if preview.lossCp >= 400 { return "Yikes." }
            return ply.isMultiple(of: 2) ? "Ouch." : "Damn."
        }
    }

    /// The verdict in words. Centipawns mean nothing to a beginner, and the
    /// engine's preferred move is deliberately left out: handing over the
    /// answer alongside a Socratic question defeats the question.
    private static func verdict(_ preview: PreviewReply?, played uci: String) -> String {
        guard let preview else { return "not measured" }
        guard let severity = preview.severity else {
            // Worth distinguishing: "fine" and "what I would have played" are
            // different facts, and only the second one is worth a word about.
            return preview.bestUci == uci
                ? "the strongest move in the position"
                : "a sound move, it gives nothing away"
        }
        return "\(severity), it costs about \(preview.lossCp) centipawns"
    }

    private static func request(_ payload: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try CoachClient.send(payload))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
