import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let fromUser: Bool
    var text: String
    var isLoading: Bool = false
    /// A rule across the panel rather than a message, used to mark where a new
    /// game starts. The panel is not only game context, so it is not cleared.
    var isDivider: Bool = false
}

private struct MoveFactsReply: Decodable {
    struct Move: Decodable {
        let san: String
        let piece: String
        let isCapture: Bool
        let givesCheck: Bool
        let attacks: [String]
        let controlsCentre: [String]
        let lossCp: Int?
        let theirBestReply: Reply?

        struct Reply: Decodable {
            let replySan: String
            let captures: String?
            let on: String?

            enum CodingKeys: String, CodingKey {
                case captures, on
                case replySan = "reply_san"
            }
        }

        enum CodingKeys: String, CodingKey {
            case san, attacks, piece
            case controlsCentre = "controls_centre"
            case isCapture = "is_capture"
            case givesCheck = "gives_check"
            case lossCp = "loss_cp"
            case theirBestReply = "their_best_reply"
        }
    }
    let moves: [Move]
    let noLegalMoveTo: [String]

    enum CodingKeys: String, CodingKey {
        case moves
        case noLegalMoveTo = "no_legal_move_to"
    }
}

/// `threats`: what the opponent would do if it were their turn.
private struct ThreatReply: Decodable {
    struct Best: Decodable {
        let san: String
        let givesCheck: Bool
        let checkmate: Bool?
        let captures: String?
        let on: String?
        let youCanTakeBackWith: [String]?
        let thenAttacks: [String]

        enum CodingKeys: String, CodingKey {
            case san, captures, on, checkmate
            case givesCheck = "gives_check"
            case youCanTakeBackWith = "you_can_take_back_with"
            case thenAttacks = "then_attacks"
        }
    }
    struct Attacked: Decodable {
        struct Piece: Decodable { let square: String; let piece: String }
        let square: String
        let piece: String
        let attackedBy: [Piece]
        let defendedBy: [Piece]

        enum CodingKeys: String, CodingKey {
            case square, piece
            case attackedBy = "attacked_by"
            case defendedBy = "defended_by"
        }
    }
    let inCheck: Bool?
    let checkedBy: [Attacked.Piece]?
    let theirBest: Best?
    let yourPiecesUnderAttack: [Attacked]?

    enum CodingKeys: String, CodingKey {
        case inCheck = "in_check"
        case checkedBy = "checked_by"
        case theirBest = "their_best"
        case yourPiecesUnderAttack = "your_pieces_under_attack"
    }
}

private struct CandidateReply: Decodable {
    struct Candidate: Decodable {
        let san: String
        /// Every legal capture of the square this move lands on.
        let theyCanCaptureItWith: [String]?
        let theirBestReply: Reply?

        struct Reply: Decodable {
            let replySan: String
            let captures: String?
            let on: String?
            let with: String?

            enum CodingKeys: String, CodingKey {
                case captures, on, with
                case replySan = "reply_san"
            }
        }

        enum CodingKeys: String, CodingKey {
            case san
            case theyCanCaptureItWith = "they_can_capture_it_with"
            case theirBestReply = "their_best_reply"
        }
    }
    let candidates: [Candidate]
    let note: String
}

/// What the user is actually looking at.
///
/// Questions used to be answered against whatever game the daemon was holding,
/// whatever tab was on screen. Asked "rook to e8 right?" during a Lichess
/// puzzle, the reply was "nothing can go to e8": true of the Play tab's board
/// and nonsense about the puzzle, where Re8 was the solution.
/// `history.py`-style advice from his own games, as `opening_advice` returns it.
private struct OpeningAdvice: Decodable {
    struct Line: Decodable {
        let name: String
        let moves: String
        let playedByPct: Int?
        enum CodingKeys: String, CodingKey {
            case name, moves
            case playedByPct = "played_by_pct"
        }
    }
    struct Family: Decodable {
        let family: String
        let games: Int
        let won: Int
        let scorePct: Int
        enum CodingKeys: String, CodingKey {
            case family, games, won
            case scorePct = "score_pct"
        }
    }
    struct Side: Decodable {
        let weakest: Family
        let strongest: Family
        let line: Line?
        enum CodingKeys: String, CodingKey {
            case weakest, strongest
            case line = "a_line_in_the_weak_one"
        }
    }
    let asWhite: Side?
    let asBlack: Side?
    enum CodingKeys: String, CodingKey {
        case asWhite = "as_white"
        case asBlack = "as_black"
    }
}

struct ViewContext: Equatable {
    /// Nil means the live game, which is the daemon's own board.
    var fen: String?
    /// A puzzle is being solved, so an answer must not give it away.
    var isPuzzle = false
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var context = ViewContext()
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var isSending: Bool = false
    private var hasWarmed = false

    /// Appends the live position and the engine's best replies to a typed
    /// question. Returns the text unchanged when no game is in progress.
    static func ask(_ payload: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                do { c.resume(returning: try CoachClient.send(payload)) }
                catch { c.resume(throwing: error) }
            }
        }
    }

    /// The maps needed to check an answer, kept from the packet that produced it.
    private struct CheckContext {
        var squares: [String: String] = [:]
        /// Where the pieces were two plies back. Without it a correct answer
        /// narrating what just happened ("your knight took on e5") is checked
        /// against the board *after* the capture and reported as an invention.
        /// The automatic coaching line has had this since it caused exactly
        /// that; typed answers were still being checked without it.
        var recent: [String: String] = [:]
        /// Square to "yours" or "theirs", and the same two plies back.
        var owners: [String: String] = [:]
        var ownersRecent: [String: String] = [:]
        var mobility: [String: String] = [:]
        var attackMap: [String: String] = [:]
        /// Every piece move and capture the answer is allowed to name: the
        /// engine's candidates and lines, the game so far, and the question
        /// itself. Empty means there was nothing to check against.
        var moves: Set<String> = []
        /// The moves the facts themselves name: every check, and the forks. A
        /// real check (Qxf7+, sitting in `your_checks`) and a fork the coach had
        /// announced a move earlier were both binned as inventions, because the
        /// allowed list was built from the candidate moves and the game and
        /// these live in neither.
        var factMoves = ""
        /// Said by the app itself, when the question has one right answer that
        /// the model would only get wrong.
        var directAnswer: String?
        /// Every check the player has, which is exhaustive. Empty means a claim
        /// that there is one is false: "you have a check with the bishop on d2"
        /// was written three times out of an empty list.
        var checks: [String] = []
    }

    /// Short questions that are about the previous answer rather than the board.
    ///
    /// "What do you mean?" after a line about a bishop came back about three
    /// unrelated moves: the packet is several hundred tokens of position and the
    /// sentence being asked about was only in the conversation, where it is
    /// outweighed. Roughly one follow-up in five drifted like that.
    static func isFollowUp(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.count <= 60 else { return false }
        // "Which piece should I move?" contains "which piece" and is a question
        // about the board, not about the last line. It was answered with "I meant
        // that the knight on a6 cannot be captured", which answers neither.
        guard !lower.contains("should"), !lower.contains("where") else { return false }
        return ["what do you mean", "what does that mean", "what did you mean", "i dont get it",
                "i don't get it", "dont get it", "explain", "simpler", "which piece", "which one",
                "how come", "so what do i do", "and then what", "huh"].contains {
            lower.contains($0)
        } || lower == "why?" || lower == "why" || lower == "why is that?"
    }

    /// The last thing shown in the panel that was not the player's own message.
    private var lastCoachLine: String? {
        messages.last { !$0.fromUser && !$0.isDivider && !$0.isLoading && !$0.text.isEmpty }?.text
    }

    private func withPosition(_ text: String) async -> (String, CheckContext) {
        let onScreen = self.context
        let asking = Self.isFollowUp(text) && lastCoachLine != nil
            ? "\n\nThey are asking about your own last line, which was: \"\(lastCoachLine!)\"\n"
                + "Answer that. Explain what you meant in plainer words; do not change the subject\n"
                + "to a different piece or start listing moves."
            : ""
        func ask(_ payload: [String: Any]) async -> String? {
            var payload = payload
            if let fen = onScreen.fen { payload["fen"] = fen }
            guard let data = try? await Self.ask(payload) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let facts = await ask(["op": "describe"]),
              !facts.contains("\"no game yet\"") else { return (text, CheckContext()) }
        var context = CheckContext()
        if let data = facts.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            context.squares = object["squares"] as? [String: String] ?? [:]
            context.recent = object["squares_recent"] as? [String: String] ?? [:]
            context.owners = object["owners"] as? [String: String] ?? [:]
            context.ownersRecent = object["owners_recent"] as? [String: String] ?? [:]
            context.mobility = object["your_mobility"] as? [String: String] ?? [:]
            context.attackMap = object["attack_map"] as? [String: String] ?? [:]
            context.checks = object["your_checks"] as? [String] ?? []
            let forks = (object["your_forks"] as? [[String: Any]] ?? [])
                .compactMap { $0["san"] as? String }
            let legal = object["legal_san"] as? [String] ?? []
            context.factMoves = " " + (context.checks + forks + legal).joined(separator: " ")
        }

        // An opening question deliberately gets no candidate moves. Asked for
        // "an idea for an opening" with three best moves sitting in the packet,
        // the model answered "Nf3, d4, or e4", which is three best moves and
        // not an opening. The loudest fact in the packet is the one that gets
        // answered with, so the wrong fact has to leave rather than be argued
        // with.
        guard !Self.isOpeningRequest(text) else {
            // Fetched here rather than left for Chichi to fetch. Told to run a
            // script, he ran the wrong one, was correctly told there was no
            // game to name, and then wrote a Reti from memory whose third move
            // was "Bg1". Handing over the answer removes the option.
            let here = await ask(["op": "opening_here"]) ?? ""
            let idea = await ask(["op": "opening_random"]) ?? ""
            // What his own 238 games say, which beats a lottery over 3,329
            // named lines where 96% are sub-variations he will never reach.
            let mine = await ask(["op": "opening_advice"]) ?? ""
            return ("""
            \(text)

            [live position, use only if the question is about the game]
            Facts: \(Facts.forModel(facts).packet)
            The opening he is already in: \(here)
            His own record, and what players at his rating do about his worst line: \(mine)
            A real line he could try instead: \(idea)
            [All three blocks came from the opening database and are the only openings
            you may name. Never write an opening's moves from memory: if it is not
            in one of those blocks, you do not have it. Quote the moves in your
            reply, because the board they set is on a tab he is not looking at.
            Prefer the line from his own record over the random one, and say what it
            is costing him: a line he has actually lost seven games in beats a line
            drawn out of a hat. `played_by_pct` is how many players at his rating
            play that move, not a win rate.]
            """, context)
        }

        // Not while a puzzle is on screen. The engine's best moves are the
        // puzzle's answer, and they were being attached to every typed question
        // regardless: "where should I move?" over a drill came back with the
        // mating line. Only the move the player names themselves is described,
        // which `answerPuzzleMove` already does without saying whether it solves it.
        if onScreen.isPuzzle {
            let (packet, _) = Facts.forModel(facts, hidingSolution: true)
            return ("""
            \(text)

            [live position, use only if the question is about the game]
            Facts: \(packet)
            [They are solving a puzzle. Describe what is on the board and what to look at.
            Never name a move: not the one that solves it, not any other. The facts that
            would give it away have been left out, so do not guess at them either.]
            """, context)
        }

        let candidates = await ask(["op": "candidates", "count": 3]) ?? ""

        // If he named a square, compute what every legal move to it does.
        // Asked "should i move it to f4?", the model said the bishop would
        // attack the pawn on e6. Three moves reach f4 here and only the knight
        // does that; it had a true fact about the wrong piece. The squares are
        // the cheapest thing to be exact about and the easiest to get wrong.
        var named = ""
        let squares = Self.squaresMentioned(text)
        if !squares.isEmpty,
           let detail = await ask(["op": "move_facts", "squares": squares]) {
            named = """

            HE IS ASKING ABOUT THESE MOVES: \(detail)
            Answer about the one he means before anything else. Asked "should I play
            b3?" the reply was "Qb3 is the strongest move", which is an answer to a
            different question. More than one piece can usually reach a square and
            they do different things, so pick the entry that matches what he said. If
            the square is under no_legal_move_to, say plainly that nothing can go there.
            """
        }

        // A piece named without a square: "how should I respond to the knight?"
        // came back about a pawn mentioned two messages earlier, because nothing
        // said which knight, what it threatened, or what the answers to it were.
        if squares.isEmpty, let piece = Self.pieceMentioned(text) {
            let lower = text.lowercased()
            let whose = lower.contains("my ") || lower.contains("mine") ? "mine" : "theirs"
            if let focus = await ask(["op": "piece_focus", "piece": piece, "whose": whose]) {
                // Asked "is my knight in trouble?" with no knight on the board,
                // the model described one anyway and the answer was binned. The
                // player is left with a shrug when the true answer is one line,
                // and the daemon already knows it.
                if let data = focus.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (object["found"] as? [[String: Any]])?.isEmpty == true {
                    context.directAnswer = whose == "mine"
                        ? "You haven't got a \(piece) on the board."
                        : "They haven't got a \(piece) on the board."
                    return (text, context)
                }
                named = """

                THE PIECE HE IS ASKING ABOUT: \(focus)
                Answer about this piece. Say what it is doing (what it attacks), then the
                best answer from `answers` and why, and if `best_move_overall` is a
                different move, say that one is stronger still. Every `line` is the
                engine's own continuation: quote it to show the plan, never extend it.
                """
            }
        }

        // Quoting the engine's lines made a plan possible, and made an invented
        // one possible too: asked for the plan, one answer gave a continuation
        // that contradicted the line it had quoted a moment before.
        let played = onScreen.fen == nil ? (await ask(["op": "state"]) ?? "") : ""
        context.moves = Self.allowedMoves(in: candidates + named + played + text
                                          + context.factMoves)

        return ("""
        \(text)\(asking)

        [live position, use only if the question is about the game]
        Facts: \(Facts.forModel(facts).packet)
        Engine's best moves here, each with the line it expects to follow: \(candidates)\(named)
        """, context)
    }

    /// A coaching line about the position just reached. The facts are computed
    /// by the engine; Chichi's only job is turning them into a sentence, so they
    /// are handed to him rather than left for him to work out.
    /// A computed observation about the position. Not from the model, so it is
    /// never wrong and never late.
    func note(_ text: String) {
        // The same fact twice running is noise. A pawn that was hanging last
        // move and is still hanging now has already been said once, and saying
        // it again is what makes a coach easy to tune out.
        if let last = messages.last(where: { !$0.isDivider }),
           !last.fromUser, last.text == text { return }

        // A note that is already written goes above one still being written.
        // The book line is a single socket call and the coaching line is a
        // model turn, so appending in completion order put a finished sentence
        // underneath a bubble that was still typing, which reads as backwards.
        if let pending = messages.lastIndex(where: { $0.isLoading }) {
            messages.insert(ChatMessage(fromUser: false, text: text), at: pending)
        } else {
            messages.append(ChatMessage(fromUser: false, text: text))
        }
    }

    func divider(_ label: String) {
        guard !messages.isEmpty else { return }
        messages.append(ChatMessage(fromUser: false, text: label, isDivider: true))
    }

    func clear() {
        messages.removeAll()
    }

    /// Wakes the session up so the first coached move does not wait 28 seconds
    /// for the model to load. Fire and forget; nothing is shown.
    func warmUp() {
        guard !hasWarmed else { return }
        hasWarmed = true
        Task { await CoachModel.warmUp() }
    }

    func coach(prompt: String,
               squares: [String: String] = [:],
               recent: [String: String] = [:],
               owners: [String: String] = [:],
               ownersRecent: [String: String] = [:],
               mobility: [String: String] = [:],
               attackMap: [String: String] = [:],
               checks: [String] = [],
               mustAsk: Bool = false,
               fallback: String = "",
               then finished: (@MainActor () -> Void)? = nil) {
        guard !isSending else { finished?(); return }
        let loadingIndex = messages.count
        messages.append(ChatMessage(fromUser: false, text: "", isLoading: true))
        isSending = true
        Task {
            defer { isSending = false; finished?() }
            do {
                // Socratic holds the board until this returns, so the wait has
                // to be bounded by patience rather than by the default. A run
                // that timed out at 180s would have left the board dead for
                // three minutes looking like a crash. Measured warm turns are
                // 5 to 35 seconds.
                var result = try await CoachModel.ask(prompt, timeoutSeconds: 60)
                // Socratic asked a question barely half the time; the rest were
                // statements, which is Notes wearing a different hat. Asking again
                // is cheaper than any wording in the instructions, which never
                // moved this at all.
                if mustAsk, !result.text.contains("?") {
                    let again = prompt + "\n\nYour reply was not a question. Reply again with "
                        + "one question about this position, ending in a question mark, and nothing else."
                    if let retry = try? await CoachModel.ask(again, timeoutSeconds: 60),
                       retry.text.contains("?") {
                        result = retry
                    }
                }
                if loadingIndex < messages.count {
                    // Three moves running it asked the same question about the
                    // same knight. Only the computed lines were deduplicated;
                    // Chichi's own were not, and his are the slower ones to sit
                    // through.
                    let prior = messages.prefix(loadingIndex)
                        .last { !$0.isDivider && !$0.fromUser }?.text
                    if result.text == prior {
                        messages.remove(at: loadingIndex)
                    } else if let wrong = Self.falseClaim(result.text, squares: squares,
                                                          recent: recent,
                                                          mobility: mobility,
                                                          attackMap: attackMap,
                                                          checks: checks,
                                                          owners: owners,
                                                          ownersRecent: ownersRecent) {
                        // Say what was caught rather than quietly swapping the
                        // text. A coach that is wrong and a coach that is
                        // covering for itself are equally hard to trust.
                        messages[loadingIndex].text =
                            "\(fallback)\n\n⚠️ Dropped a line that described \(wrong)."
                    } else {
                        messages[loadingIndex].text = result.text
                    }
                    messages[loadingIndex].isLoading = false
                }
            } catch {
                // Say what went wrong, and say the board is yours again. Silently
                // dropping the bubble makes a broken coach look like a quiet one,
                // and saying nothing about the board makes a freed one look stuck.
                if loadingIndex < messages.count {
                    messages[loadingIndex].text =
                        "⚠️ \(Self.explain(error)) Play on; the board is not waiting."
                    messages[loadingIndex].isLoading = false
                }
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""

        messages.append(ChatMessage(fromUser: true, text: text))

        // Nothing to do with the board: who I am, how the app works. Answered
        // from the app's own words, for the same reason the move list is.
        if let answer = Self.appAnswer(text) {
            note(answer)
            return
        }

        // "What are my options" has exactly one right answer, so it comes from
        // the engine rather than the model. Three attempts at getting Chichi to
        // relay the list faithfully all ended with him naming a favourite among
        // moves the engine rated identically.
        if Self.isOptionsRequest(text) {
            Task {
                if await answerOptionsDirectly() { return }
                sendToChichi(text)
            }
            return
        }

        // A move named while a puzzle is on screen gets answered from the
        // puzzle's own board, and answered without giving the puzzle away.
        if context.isPuzzle, !Self.squaresMentioned(text).isEmpty {
            Task {
                if await answerPuzzleMove(text) { return }
                sendToChichi(text)
            }
            return
        }

        // What they are threatening is a computed fact too, and was the last
        // place an answer could still be invented outright.
        if Self.isThreatQuestion(text) {
            Task {
                if await answerThreatDirectly() { return }
                sendToChichi(text)
            }
            return
        }

        // "He can just take my bishop, no?" is a question about legality, which
        // has one answer. He asked exactly that, was told "No, they cannot",
        // played Bxf7+ and lost the bishop to Kxf7. Putting the capture list in
        // the packet did not fix it: asked again with the true answer in front
        // of it, the model still said no. So the engine answers this one.
        if Self.isCaptureQuestion(text) {
            Task {
                if await answerCaptureDirectly() { return }
                sendToChichi(text)
            }
            return
        }

        // Which opening to work on is arithmetic over his own games, so it is
        // arithmetic that answers. Handed the same figures as a packet the
        // model stitched a name out of one block onto the moves of another and
        // offered "1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Nf3/Nc3", which is not a
        // move. More true blocks in a packet is more to recombine.
        if Self.isOpeningRequest(text) {
            Task {
                if await answerOpeningDirectly() { return }
                sendToChichi(text)
            }
            return
        }
        sendToChichi(text)
    }

    /// Conservative on purpose: only short, unambiguous asks are intercepted.
    /// True when every move-shaped token in `line` is one of `moves`.
    ///
    /// Asked to comment on Na3, Nh3 and c4, the model produced a sentence about
    /// Bc4, which was not among them. A line that names a move Jordan cannot
    /// play is worse than no line, so it is dropped rather than shown.
    /// A claim that one piece attacks or defends another, checked both ways.
    ///
    /// "Your knight on c3 is attacked by the bishop on f5 and defended only by
    /// the pawn on d4" put every piece on its real square and got both
    /// relationships wrong: f5 attacks the knight on h3, and a pawn on d4
    /// covers c5 and e5. Only a map of what attacks what can refute that.
    ///
    /// Squares with no piece on them are skipped, so a sentence about what a
    /// move *would* attack is not judged against the board before it.
    static func falseRelation(_ line: String, attackMap: [String: String]) -> String? {
        guard !attackMap.isEmpty else { return nil }
        let piece = "king|queen|rook|bishop|knight|pawn"
        // "<subject> on s1 ... attacked/defended by the <piece> on s2"
        // Nothing between the subject and the claim may itself be an "on
        // <square>", or the first square in the sentence is read as the subject:
        // "the knight on b7 can capture your queen on d8 because it is only
        // defended by your rook on f8" was checked as "does f8 defend b7", and a
        // true sentence was binned.
        // Also stops at a clause boundary, because a question is not a claim:
        // "with your king now on e2, which piece is defending the knight on f4?"
        // was read as "e2 defends f4" and a perfectly good Socratic question was
        // dropped. Same for "protect your rook on c1 while attacking their knight
        // on d7", which is two things about two squares, not one claim about both.
        let gap = "(?:(?!\\b(?:on|at)\\s+[a-h][1-8])(?!\\b(?:while|which|instead|whereas)\\b)[^.!?,])"
        let passive = "(?:on|at)\\s+([a-h][1-8])\(gap){0,80}?"
            + "\\b(?:attacked|defended|protected|covered)\\s+(?:only\\s+)?by\\s+"
            + "(?:the\\s+|their\\s+|your\\s+)*(?:\(piece))\\s+(?:on|at)\\s+([a-h][1-8])"
        // "<piece> on s2 ... attacks/defends the <piece> on s1"
        let active = "(?:on|at)\\s+([a-h][1-8])\(gap){0,60}?"
            + "\\b(?:attacks|attacking|defends|defending|hits|covers)\\s+"
            + "(?:the\\s+|their\\s+|your\\s+)*(?:\(piece))\\s+(?:on|at)\\s+([a-h][1-8])"

        for (pattern, subjectFirst) in [(passive, true), (active, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: .caseInsensitive) else { continue }
            let text = line as NSString
            for m in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
                let a = text.substring(with: m.range(at: 1)).lowercased()
                let b = text.substring(with: m.range(at: 2)).lowercased()
                let subject = subjectFirst ? a : b
                let actor = subjectFirst ? b : a
                guard let reaches = attackMap[actor] else { continue }
                if !reaches.split(separator: " ").contains(Substring(subject)) {
                    return "\(actor) as attacking or defending \(subject), which it does not"
                }
            }
        }
        return nil
    }

    /// A claim that a piece is stuck, checked against where it can actually go.
    ///
    /// "Your knight on c3 is now blocked by your pawn on d4" passes every board
    /// check ever written: the knight is on c3, the pawn is on d4, and knights
    /// are not blocked by pawns. That one had five moves. Squares being right
    /// is not the same as the sentence being true.
    ///
    /// A pawn needs two moves before "blocked" counts as wrong, because a pawn
    /// that cannot advance but can still capture is fairly called blocked.
    static func falseImmobility(_ line: String, mobility: [String: String]) -> String? {
        guard !mobility.isEmpty else { return nil }
        let pattern = "\\b(king|queen|rook|bishop|knight|pawn)s?\\s+(?:on|at)\\s+"
            + "([a-h][1-8])[^.!?]{0,60}?\\b(blocked|trapped|stuck|boxed in|immobile"
            + "|cannot move|can't move|has no moves|no legal moves|nowhere to go)"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: .caseInsensitive) else { return nil }
        let text = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let piece = text.substring(with: match.range(at: 1)).lowercased()
            let square = text.substring(with: match.range(at: 2)).lowercased()
            guard let targets = mobility[square], !targets.isEmpty else { continue }
            let count = targets.split(separator: " ").count
            // A piece with a single square to go to is fairly called trapped, by
            // anyone. "Your rook on g1 is now trapped on the g-file" was dropped
            // over one legal move, and it was a reasonable thing to say.
            if count < 2 { continue }
            return "a \(piece) on \(square) being stuck when it has \(count) move"
                + (count == 1 ? "" : "s")
        }
        return nil
    }

    /// A piece claimed as the player's when it is the opponent's, or the other
    /// way round.
    ///
    /// "Your pawn on f7 is undefended and can be taken by your rook on f1"
    /// names two of their pieces as his. Every other check passed it: the pawn
    /// really was on f7, the rook really was on f1, and nothing until now knew
    /// whose they were.
    ///
    /// A capture changes who owns a square, so a sentence about what just
    /// happened is checked against the board two plies back as well.
    static func falseOwner(_ line: String, owners: [String: String],
                           recent: [String: String]) -> String? {
        guard !owners.isEmpty else { return nil }
        let pattern = "\\b(your|their|his|her|its|my)\\s+(?:own\\s+)?"
            + "(king|queen|rook|bishop|knight|pawn)s?\\s+(?:on|at)\\s+([a-h][1-8])\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: .caseInsensitive) else { return nil }
        let text = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let said = text.substring(with: match.range(at: 1)).lowercased()
            let piece = text.substring(with: match.range(at: 2)).lowercased()
            let square = text.substring(with: match.range(at: 3)).lowercased()
            // "my" is the coach speaking about nothing real; the player is "you".
            let claimed = ["your", "my"].contains(said) ? "yours" : "theirs"
            guard let owner = owners[square] else { continue }
            if owner != claimed && recent[square] != claimed {
                return "the \(piece) on \(square) as \(said == "your" ? "yours" : "theirs"), "
                    + "when it is \(owner == "yours" ? "yours" : "theirs")"
            }
        }
        return nil
    }

    /// A check offered when the player does not have one.
    ///
    /// `your_checks` is exhaustive, so an empty list makes "you have a check with
    /// the bishop on d2" false before the board is even consulted. Three answers
    /// in one test run said exactly that, and they were caught only because the
    /// square they named happened to hold the wrong piece.
    static func falseCheckOffer(_ line: String, checks: [String]) -> String? {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: .caseInsensitive) else { return [] }
            return regex.matches(in: line, range: whole)
        }
        let offered = "\\b(?:you\\s+have|you've\\s+got|there\\s+is|there's)\\s+"
            + "(?:an?\\s+)?(?:immediate\\s+|free\\s+|strong\\s+)?check\\b"
        if checks.isEmpty {
            return matches(offered).isEmpty ? nil : "a check that is not in the position"
        }
        // There is a check, but is it that piece's? "You have a check with the
        // bishop on b5" names a piece as well as a fact, and the piece is the
        // half that gets invented. SAN says which kind gives each check.
        let letters: [String: Character] = ["king": "K", "queen": "Q", "rook": "R",
                                            "bishop": "B", "knight": "N"]
        for m in matches("check\\s+(?:with|from|by)\\s+(?:the\\s+|your\\s+)*"
                         + "(king|queen|rook|bishop|knight|pawn)") {
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            let available = checks.contains { check in
                guard let letter = letters[kind] else { return check.first.map { !$0.isUppercase } ?? false }
                return check.first == letter
            }
            if !available { return "a check given by a \(kind), which has none here" }
        }
        return nil
    }

    /// Every "<piece> on <square>" claim, checked against the board it was
    /// meant to describe. Returns the first claim that is wrong, or nil.
    ///
    /// The model once reported a knight on f3 in a position where f3 held a
    /// pawn and the knight had never left g1. It had been given no board at
    /// all, so it reached for the worked example in its own instructions. The
    /// board is in the packet now; this is what makes sure it was read.
    static func falseClaim(_ line: String, squares: [String: String],
                           recent: [String: String] = [:],
                           mobility: [String: String] = [:],
                           attackMap: [String: String] = [:],
                           checks: [String] = [],
                           owners: [String: String] = [:],
                           ownersRecent: [String: String] = [:]) -> String? {
        if let wrong = falseOwner(line, owners: owners, recent: ownersRecent) { return wrong }
        if let wrong = falseImmobility(line, mobility: mobility) { return wrong }
        if let wrong = falseRelation(line, attackMap: attackMap) { return wrong }
        if let wrong = falseCheckOffer(line, checks: checks) { return wrong }
        guard !squares.isEmpty else { return nil }
        let pattern = "\\b(king|queen|rook|bishop|knight|pawn)s?\\s+(?:on|at)\\s+([a-h][1-8])\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: .caseInsensitive) else { return nil }
        let text = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let claimed = text.substring(with: match.range(at: 1)).lowercased()
            let square = text.substring(with: match.range(at: 2)).lowercased()
            // "There is no knight on h3" says the same thing this check does, and
            // was binned for saying it. A denial of a piece is never a false claim
            // about one.
            let start = max(0, match.range.location - 18)
            let before = text.substring(with: NSRange(location: start,
                                                      length: match.range.location - start)).lowercased()
            if ["no ", "not ", "n't ", "nothing ", "isn't", "no longer"].contains(where: before.contains) {
                continue
            }
            // True of the board now, or of the board it is narrating.
            if squares[square] != claimed && recent[square] != claimed {
                return "a \(claimed) on \(square)"
            }
        }
        return nil
    }

    /// What to say when the model does not answer.
    ///
    /// `localizedDescription` for a timeout is "The request timed out", which
    /// tells somebody staring at a chess app precisely nothing about what to do.
    static func explain(_ error: Error) -> String {
        if let ollama = error as? OllamaError { return ollama.errorDescription ?? "\(ollama)" }
        if (error as? URLError)?.code == .timedOut {
            return "Chichi took too long, so I stopped waiting. The first question after "
                + "opening Rookie can be slow while the model loads, so it is worth one more try; "
                + "if it keeps happening, check Ollama is running."
        }
        return error.localizedDescription
    }

    /// Piece moves and captures written in SAN, check marks dropped. Plain pawn
    /// pushes are not matched here, so "the pawn on b4" is never taken for a move.
    static func sanTokens(in text: String) -> Set<String> {
        matches("\\b(?:[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|O-O(?:-O)?)(?:=[QRBN])?", in: text)
    }

    /// Every move quoted inside a numbered line ("7. d4 a5", "7...a5"). This is
    /// where pawn pushes are caught: an invented continuation that was nothing
    /// but pawn moves got straight past a check that only looked at pieces.
    static func quotedLineMoves(in text: String) -> Set<String> {
        let move = "(?:[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8]|O-O(?:-O)?)(?:=[QRBN])?"
        let pattern = "\\d+\\.(?:\\.\\.)?\\s*(\(move))[+#]?(?:\\s+(\(move)))?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out = Set<String>()
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for g in 1...2 where m.range(at: g).location != NSNotFound {
                out.insert(ns.substring(with: m.range(at: g)))
            }
        }
        return out
    }

    /// Everything move-shaped in the packet, pawn pushes included. Generous on
    /// purpose: this is what an answer may name, not what it must.
    static func allowedMoves(in text: String) -> Set<String> {
        matches("\\b(?:[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8]|O-O(?:-O)?)(?:=[QRBN])?", in: text)
    }

    private static func matches(_ pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) })
    }

    /// The first move in `answer` that nothing it was given contains, or nil.
    /// Sentences that say a move is *not* on. "Taking the knight with Bxc4 is not
    /// possible as there is no knight on c4" is the right answer to a question
    /// about a piece that is not there, and naming the move it is refusing does
    /// not make it an invention.
    private static func denied(_ move: String, in answer: String) -> Bool {
        for sentence in answer.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        where sentence.contains(move) {
            let lower = sentence.lowercased()
            if ["not possible", "isn't possible", "is not legal", "cannot", "can't",
                "there is no", "there's no", "no longer", "not able"].contains(where: lower.contains) {
                return true
            }
        }
        return false
    }

    static func inventedMove(_ answer: String, allowed: Set<String>) -> String? {
        guard !allowed.isEmpty else { return nil }
        // "Qb1" for Qxb1 is sloppy notation, not an invented move, and binning
        // the answer cost the player a correct one. Compared without the x, the
        // piece and the square still have to match.
        let bare = Set(allowed.map { $0.replacingOccurrences(of: "x", with: "") })
        return sanTokens(in: answer).union(quotedLineMoves(in: answer)).sorted()
            .first { !allowed.contains($0)
                && !bare.contains($0.replacingOccurrences(of: "x", with: ""))
                && !denied($0, in: answer) }
    }

    static func mentionsOnly(_ moves: [String], in line: String) -> Bool {
        let allowed = Set(moves)
        // SAN: an optional piece letter, optional disambiguation, optional x,
        // a file and a rank, optional promotion and check marks.
        let pattern = "\\b(?:[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x?[a-h][1-8]|O-O(?:-O)?)(?:=[QRBN])?[+#]?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
        let range = NSRange(line.startIndex..., in: line)
        for match in regex.matches(in: line, range: range) {
            guard let r = Range(match.range, in: line) else { continue }
            let token = String(line[r]).trimmingCharacters(in: CharacterSet(charactersIn: "+#"))
            let bare = allowed.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+#")) }
            if !bare.contains(token) { return false }
        }
        return true
    }

    /// He is told not to repeat the move list and sometimes does anyway. Rather
    /// than print it twice, drop a leading restatement.
    private static func stripRepeatedList(_ raw: String, moves: [String]) -> String {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = moves.first, line.hasPrefix(first) else { return line }
        // Cut at the first sentence break; if what follows is empty, keep the original.
        if let stop = line.firstIndex(where: { $0 == "." || $0 == ":" }) {
            let rest = line[line.index(after: stop)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.count > 12 { line = rest }
        }
        return line
    }

    /// Board squares named in a message: "f4", "Bf4", "move it to f4".
    ///
    /// The lookbehind rejects a letter-digit pair inside an ordinary word while
    /// still allowing a SAN piece letter in front, since that is uppercase.
    static func squaresMentioned(_ text: String) -> [String] {
        let pattern = "(?<![a-z0-9])[a-h][1-8](?![0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let square = ns.substring(with: match.range).lowercased()
            if !out.contains(square) { out.append(square) }
        }
        return Array(out.prefix(3))
    }

    /// Is he asking about opening theory rather than this position? Broad on
    /// purpose: the cost of a false positive is that a move question gets
    /// answered without the candidate list, and Chichi can always ask the
    /// engine for it. The cost of a false negative is the bug this fixes.
    static func isOpeningRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["opening", "gambit", "defense", "defence", "variation",
                "repertoire", "book line", "theory"].contains { lower.contains($0) }
    }

    private static func isOptionsRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.count <= 60 else { return false }
        let phrases = ["option", "what can i play", "what should i play",
                       "candidate", "suggestion", "what would you play",
                       "give me a hint", "any ideas", "what are my moves"]
        return phrases.contains { lower.contains($0) }
    }

    /// False when there is no game on, so the question falls through to Chichi.
    ///
    /// The engine owns the list and the verdict, because those have one correct
    /// answer. Chichi then adds a line about what the moves actually do, which
    /// is the part worth a model. His line is appended to the same bubble so it
    /// reads as one answer rather than two.
    /// What a move named during a drill would do, without saying whether it
    /// solves the puzzle.
    ///
    /// Jordan asked for this shape directly: not "obviously yes", but what the
    /// move does, and a steer away from it if it is bad. So the sentence reads
    /// the same whether the move is the answer or merely playable, and only a
    /// move that actually costs something is talked out of. Confirming the
    /// solution would end the puzzle, which is the one thing a drill is for.
    private func answerPuzzleMove(_ text: String) async -> Bool {
        let squares = Self.squaresMentioned(text)
        guard let fen = context.fen,
              let data = try? await Self.ask(["op": "move_facts", "fen": fen,
                                              "squares": squares, "judge": true]),
              let reply = try? JSONDecoder().decode(MoveFactsReply.self, from: data)
        else { return false }

        if reply.moves.isEmpty {
            guard !reply.noLegalMoveTo.isEmpty else { return false }
            note("Nothing can go to \(reply.noLegalMoveTo.joined(separator: " or ")) here.")
            return true
        }
        // "knight to d5" is a question about the knight. Two moves reached d5
        // in the first live test and both were described, which is the same
        // fault as answering "should I play b3?" with Qb3.
        let named = Self.pieceMentioned(text)
        let wanted = named.map { name in reply.moves.filter { $0.piece == name } } ?? []
        let moves = wanted.isEmpty ? reply.moves : wanted
        note(moves.map(Self.puzzleLine).joined(separator: " "))
        return true
    }

    /// The piece named in a question, if one is.
    static func pieceMentioned(_ text: String) -> String? {
        let lower = text.lowercased()
        let names = ["knight", "bishop", "rook", "queen", "king", "pawn"]
        if let word = names.first(where: { lower.contains($0) }) { return word }
        // SAN's piece letters, which are uppercase and so cannot be confused
        // with an ordinary word.
        for (letter, name) in [("N", "knight"), ("B", "bishop"), ("R", "rook"),
                               ("Q", "queen"), ("K", "king")]
        where text.contains(letter) && text.range(of: "\(letter)[a-h][1-8]",
                                                  options: .regularExpression) != nil {
            return name
        }
        return nil
    }

    /// One move, described from computed facts.
    fileprivate static func puzzleLine(_ move: MoveFactsReply.Move) -> String {
        var does: [String] = []
        if move.givesCheck { does.append("is check") }
        if move.isCapture { does.append("takes material") }
        // The king is dropped when the move is already described as check:
        // "is check and hits the king on h8" says the same thing twice.
        let hit = move.attacks.filter { !($0.hasPrefix("king") && move.givesCheck) }
        if !hit.isEmpty {
            does.append("hits the " + hit.joined(separator: " and the "))
        }
        if does.isEmpty && !move.controlsCentre.isEmpty {
            does.append("covers " + move.controlsCentre.joined(separator: " and "))
        }
        let what = does.isEmpty ? "is legal, and does nothing in particular"
                                : does.joined(separator: " and ")
        var line = "\(move.san) \(what)."

        // Only a move that genuinely costs something gets talked out of. Every
        // other move gets the same follow-up, so the wording cannot be read as
        // a yes or a no.
        if let loss = move.lossCp, loss >= 100 {
            if let r = move.theirBestReply, let captured = r.captures, let on = r.on {
                line += " But they answer \(r.replySan), taking the \(captured) on \(on)."
            } else if let r = move.theirBestReply {
                line += " But they answer \(r.replySan) and you are worse."
            } else {
                line += " It gives away more than it wins."
            }
            line += " Look for something else."
        } else if let r = move.theirBestReply {
            line += " They answer \(r.replySan). Work out what you have after that."
        }
        return line
    }

    /// Questions about the coach or the app, which the app answers itself.
    ///
    /// These have one right answer and the model had none of them: "what does
    /// chichi mean?" got "The position does not tell me that", "how do I make
    /// this easier?" got a line about castling, and one answer sent someone to a
    /// help section that does not exist. Written into the persona instead, the
    /// example sentences came back out word for word three times running, which
    /// is the same lesson this project keeps relearning: a sentence handed to the
    /// model is a sentence it repeats. So these are literals, and they are right.
    static func appAnswer(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.count <= 90 else { return nil }
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }

        if has(["what does chichi", "why are you called", "what's your name", "whats your name"])
            || (lower.contains("chichi") && has(["mean", "name", "called"])) {
            return "It doesn't mean anything much. It sounds like \"cheat sheet\", which is what "
                + "I'm holding. Beyond that: I'm the coach here, and I run on your own machine."
        }
        if has(["who are you", "are you a robot", "are you a bot", "are you human", "are you an ai",
                "do you actually know chess", "are you guessing"]) {
            return "A chess coach in an app, running on your Mac through Ollama. Everything I tell "
                + "you about the board is worked out by a real engine before it reaches me, so it "
                + "is not guesswork, though the sentence around it is mine."
        }
        if has(["play for me", "play it for me", "do it for me", "can you play"]) {
            return "No. You play, I talk. Ask me what a move does before you make it and you get "
                + "most of the benefit anyway."
        }
        // "take that move back" matched none of the fixed phrases and fell through
        // to the model, which said the position did not tell it that.
        let wantsTakeback = lower.contains("takeback") || lower.contains("undo")
            || (lower.range(of: "\\btak(e|ing)\\b[^.?]{0,20}\\bback\\b",
                            options: .regularExpression) != nil)
        if wantsTakeback {
            return "Take back is under the board. It undoes your move and my reply together, so "
                + "you land back on your own turn."
        }
        if has(["easier", "harder", "too hard", "difficulty", "weaker opponent", "stronger opponent"]) {
            return "The level picker sits beside the board: eight rungs, 1 the weakest. Each one "
                + "genuinely beats the one below it, so dropping a rung is a real change, not a "
                + "placebo."
        }
        if has(["board colour", "board color", "change the board", "piece set", "pieces look",
                "different pieces"]) {
            return "The gear at the top right. Board themes and piece sets are both in there."
        }
        if has(["old games", "past games", "my games", "my history", "my rating"]) {
            return "The Review tab. It pulls in your chess.com games and analyses them, once "
                + "you've linked the account in settings."
        }
        // Whether they are improving is arithmetic over their own games, and the
        // position in front of them says nothing about it. Asked mid-game, the
        // model answered with the queen on f3 being attacked.
        if has(["getting any better", "am i improving", "am i getting better", "how am i doing"]) {
            return "Not something this position can tell you. The Review tab has it: every game "
                + "you've played, what they cost you, and which openings keep going wrong."
        }
        return nil
    }

    /// Is he asking what the opponent is up to?
    ///
    /// Nothing in the packet used to answer this: every fact in it is about what
    /// the player can do. So the model made one up, and in one test run told
    /// somebody on move two that "they have a check with the bishop on b4".
    static func isThreatQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.count <= 90 else { return false }
        func has(_ words: [String]) -> Bool {
            let pattern = "\\b(" + words.joined(separator: "|") + ")\\b"
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
        // "What is HE threatening" and not "what am I threatening".
        guard has(["he", "they", "him", "them", "his", "their", "theirs", "opponent"]) else {
            return false
        }
        return has(["threatening", "threat", "threats", "plan", "planning", "up"])
            || lower.contains("going to do") || lower.contains("want to do")
            || lower.contains("doing")
    }

    /// Is he asking whether the opponent can take something?
    static func isCaptureQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.count <= 90 else { return false }
        // Whole words only: "the knight" contains "he ", and matching on
        // substrings had this intercepting "can I take the knight?", which is
        // a question about him and not about them.
        func mentions(_ words: [String]) -> Bool {
            let pattern = "\\b(" + words.joined(separator: "|") + ")\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let ns = lower as NSString
            return regex.firstMatch(in: lower,
                                    range: NSRange(location: 0, length: ns.length)) != nil
        }
        return mentions(["take", "takes", "taking", "capture", "captures",
                         "capturing", "recapture", "recaptures"])
            && mentions(["he", "they", "him", "them", "opponent", "his", "their"])
    }

    /// Answers it from the engine. Says yes or no, names the capture, and does
    /// not quietly drop the fact that the move is still the best one: a
    /// sacrifice is a good move *and* the piece comes off, and hiding either
    /// half is how he ended up distrusting the right answer.
    /// What to work on, said the way a person would say it. Every number here
    /// is counted, and every move is quoted from the opening list.
    private func answerOpeningDirectly() async -> Bool {
        guard let data = try? await Self.ask(["op": "opening_advice"]),
              let advice = try? JSONDecoder().decode(OpeningAdvice.self, from: data)
        else { return false }

        // Whichever side he is worse on, so the advice is about the half of his
        // chess that is actually leaking.
        let sides = [("White", advice.asWhite), ("Black", advice.asBlack)]
            .compactMap { label, side in side.map { (label, $0) } }
        guard let (colour, side) = sides.min(by: { $0.1.weakest.scorePct < $1.1.weakest.scorePct }),
              let line = side.line else { return false }

        let w = side.weakest
        var out = "Your worst line is the \(w.family) as \(colour.lowercased()): "
            + "\(w.won) win\(w.won == 1 ? "" : "s") from \(w.games) games. "
        // "the French Defense as white ... the French Defense: Advance Variation:"
        // says the family twice and then colons twice. Drop the half already said.
        let variation = line.name.hasPrefix(w.family)
            ? line.name.dropFirst(w.family.count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            : line.name
        out += "The usual answer is the \(variation.isEmpty ? line.name : variation).\n\n"
            + "\(line.moves)\n\n"
        if let share = line.playedByPct {
            out += "\(share)% of players around your rating play that move. "
        }
        out += "It is on the Explore tab now, so you can step through it, "
            + "and \"Play \(GameStore.family(line.name))\" in the Play tab will "
            + "steer a game towards it.\n\n"
        out += "For contrast, your best is the \(side.strongest.family), "
            + "\(side.strongest.won) from \(side.strongest.games)."
        note(out)
        return true
    }

    /// What they are threatening, from the engine rather than from the model.
    ///
    /// Two sentences at most: the move they want, and what of yours is already
    /// under something. Written by the app, so it cannot be a guess.
    private func answerThreatDirectly() async -> Bool {
        guard let data = try? await Self.ask(["op": "threats"]),
              let reply = try? JSONDecoder().decode(ThreatReply.self, from: data) else { return false }

        if reply.inCheck == true {
            let by = (reply.checkedBy ?? [])
                .map { "the \($0.piece) on \($0.square)" }.joined(separator: " and ")
            note("You're in check from \(by.isEmpty ? "their last move" : by), so that comes "
                 + "first: move the king, block it, or take the piece giving it.")
            return true
        }
        guard let best = reply.theirBest else { return false }

        var line: String
        if best.checkmate == true {
            line = "\(best.san) is mate. That is the threat, and it has to be stopped now."
        } else if let taken = best.captures, let on = best.on {
            line = "They want \(best.san), taking your \(taken) on \(on)."
            if let back = best.youCanTakeBackWith, !back.isEmpty {
                line += " You could take back with \(back.joined(separator: " or "))."
            } else {
                line += " Nothing of yours takes back on that square."
            }
        } else if best.givesCheck {
            line = "Their best is \(best.san), which is check."
        } else {
            line = "Nothing sharp: their best is \(best.san)."
            if !best.thenAttacks.isEmpty {
                line += " After it, it hits your \(best.thenAttacks.joined(separator: " and your "))."
            }
        }

        // What is already under attack, which is the half they can see for
        // themselves once it is pointed at.
        let loose = (reply.yourPiecesUnderAttack ?? []).filter { $0.defendedBy.isEmpty }
        if let first = loose.first {
            line += " Your \(first.piece) on \(first.square) is also sitting there undefended."
        }
        note(line)
        return true
    }

    private func answerCaptureDirectly() async -> Bool {
        guard let data = try? await Self.ask(["op": "candidates", "count": 3]),
              let reply = try? JSONDecoder().decode(CandidateReply.self, from: data),
              let best = reply.candidates.first else { return false }

        let takers = best.theyCanCaptureItWith ?? []
        var line: String
        if takers.isEmpty {
            line = "No. After \(best.san) there is no legal capture of that square."
        } else {
            line = "Yes. After \(best.san) they can take with "
                + takers.joined(separator: " or ") + "."
            if let r = best.theirBestReply, let captured = r.captures, let on = r.on,
               let piece = r.with, r.replySan == takers.first {
                line = "Yes. After \(best.san) they play \(r.replySan), taking the "
                    + "\(captured) on \(on) with the \(piece)."
            }
            line += " \(best.san) is still the engine's first choice, so it means "
                + "giving that up on purpose."
        }
        note(line)
        return true
    }

    private func answerOptionsDirectly() async -> Bool {
        guard let data = try? await Self.ask(["op": "candidates", "count": 3]),
              let reply = try? JSONDecoder().decode(CandidateReply.self, from: data),
              !reply.candidates.isEmpty else { return false }

        let moves = reply.candidates.map { $0.san }
        let list = moves.count > 1
            ? moves.dropLast().joined(separator: ", ") + " or " + moves[moves.count - 1]
            : moves[0]
        let spine = list + ". " + reply.note
        note(spine)
        let index = messages.count - 1

        guard !isSending else { return true }
        isSending = true
        Task {
            defer { isSending = false }
            // Hand over what each move actually does. Given only the move names
            // the model called a knight going to h3 "developing to a central
            // square"; with the computed facts it has something true to say.
            let moveFacts = String(data: data, encoding: .utf8) ?? "{}"
            let prompt = """
            [move options, mode=colour]
            The player asked what their options were, and has already been shown this, verbatim:
            "\(spine)"
            What each move does, computed: \(moveFacts)

            Add ONE short sentence about what these moves do or what they are for,
            using only those facts. Do not repeat the move names. Do not say which is
            best; that is already said. Do not mention any move outside
            \(moves.joined(separator: ", ")).
            """
            if let result = try? await CoachModel.ask(prompt),
               index < messages.count {
                let line = Self.stripRepeatedList(result.text, moves: moves)
                // Trust nothing: if the sentence names a move that is not on the
                // list, it was invented, and the answer is better without it.
                if Self.mentionsOnly(moves, in: line), !line.isEmpty, line.count <= 160 {
                    messages[index].text = spine + " " + line
                }
            }
        }
        return true
    }

    private func sendToChichi(_ text: String) {
        let loadingIndex = messages.count
        messages.append(ChatMessage(fromUser: false, text: "", isLoading: true))
        isSending = true

        Task {
            defer { isSending = false }
            do {
                // Anything typed while a game is on gets the position attached,
                // so "why?" and "what are my options?" mean something. The
                // engine's candidate moves ride along here and deliberately not
                // in the automatic Socratic packet.
                let (message, context) = await withPosition(text)
                if let direct = context.directAnswer {
                    messages[loadingIndex].text = direct
                    messages[loadingIndex].isLoading = false
                    return
                }
                // Bounded by patience, not by the default. With the model's
                // backend down, a typed question sat on a loading bubble for the
                // full three minutes and then said "The request timed out".
                let result = try await CoachModel.ask(message, timeoutSeconds: 60)
                if loadingIndex < messages.count {
                    // Typed answers went unchecked until a line saying "he
                    // cannot take your bishop" cost a bishop to Kxf7. The
                    // answer is still shown, because he asked a question and
                    // deserves one, but the warning goes first so it is read
                    // before the sentence it is about.
                    let wrong = Self.falseClaim(result.text, squares: context.squares,
                                                recent: context.recent,
                                                mobility: context.mobility,
                                                attackMap: context.attackMap,
                                                checks: context.checks,
                                                owners: context.owners,
                                                ownersRecent: context.ownersRecent)
                    // Showing the answer under a warning not to trust it is the
                    // worst of both: he asked because he could not read the
                    // position himself, so he cannot tell which half was wrong.
                    // Say it could not be answered, and let him ask again.
                    let invented = wrong == nil
                        ? Self.inventedMove(result.text, allowed: context.moves) : nil
                    if wrong != nil {
                        messages[loadingIndex].text = "I nearly told you something that isn't on "
                            + "the board, so I've binned it. Ask me again, or ask about one piece."
                    } else if invented != nil {
                        messages[loadingIndex].text = "I nearly gave you a move the engine didn't, "
                            + "so I've binned it. Ask me again."
                    } else {
                        messages[loadingIndex].text = result.text
                    }
                    messages[loadingIndex].isLoading = false
                }
            } catch {
                if loadingIndex < messages.count {
                    messages[loadingIndex].text = "⚠️ \(Self.explain(error))"
                    messages[loadingIndex].isLoading = false
                }
            }
        }
    }
}
