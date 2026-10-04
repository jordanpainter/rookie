import SwiftUI

private enum BoardMode: String, CaseIterable {
    case play = "Play"
    case explore = "Explore"
    case review = "Review"
    case drill = "Drill"
}

struct CardView: View {
    @EnvironmentObject var boardState: BoardState
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var game: GameStore
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var drill: DrillStore
    @EnvironmentObject var appearance: Appearance
    @EnvironmentObject var openingDrill: OpeningDrillStore
    @EnvironmentObject var openings: OpeningSearch
    @EnvironmentObject var endgame: EndgameStore
    @State private var mode: BoardMode = .play
    @FocusState private var searchFocused: Bool
    @FocusState private var chatFocused: Bool
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: $mode) {
                        ForEach(BoardMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    appearanceMenu
                    settingsButton
                }

                switch mode {
                case .explore: exploreBoard
                case .play:    playBoard
                case .review:  ReviewView()
                case .drill:   DrillView()
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.leading, 4)
            .onChange(of: game.coaching) {
                if game.coaching.usesModel { chat.warmUp() }
            }
            .onChange(of: game.bookLine) {
                if let line = game.bookLine {
                    chat.note(line)
                    game.bookLine = nil
                }
            }
            .onChange(of: game.coachingPrompt) {
                if let prompt = game.coachingPrompt {
                    chat.coach(prompt: prompt,
                               squares: game.coachingSquares,
                               recent: game.coachingSquaresRecent,
                               owners: game.coachingOwners,
                               ownersRecent: game.coachingOwnersRecent,
                               mobility: game.coachingMobility,
                               attackMap: game.coachingAttackMap,
                               checks: game.coachingChecks,
                               mustAsk: game.coachingMustAsk,
                               fallback: game.coachingFallback) {
                        game.awaitingCoach = false
                    }
                    game.coachingPrompt = nil
                }
            }

            Divider().overlay(Color.primary.opacity(0.15))

            chatPanel
        }
        .padding(16)
        .frame(width: CardSize.width, height: CardSize.height)
        .background(VisualEffectBackground())
        .onAppear { chat.context = viewContext }
        .onChange(of: viewContext) { chat.context = viewContext }
    }

    /// The board the question is about. Without this every typed question was
    /// answered against whatever game the daemon held, whatever was on screen:
    /// "rook to e8 right?" during a puzzle came back "nothing can go to e8",
    /// which was true of the Play tab and wrong about the puzzle, where Re8 was
    /// the answer.
    private var viewContext: ViewContext {
        switch mode {
        case .play, .review:
            return ViewContext()
        case .explore:
            return ViewContext(fen: boardState.fen, isPuzzle: false)
        case .drill:
            return drill.source.isPuzzle
                ? ViewContext(fen: drill.puzzle?.positionFen, isPuzzle: true)
                : ViewContext(fen: endgame.state?.fen, isPuzzle: false)
        }
    }

    /// Board look and piece style. Beside the tabs rather than inside one,
    /// because every tab draws the same board.
    /// Everything that is about you rather than about chess: which account
    /// your games come from, what that rating implies, and which side you take.
    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 22)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            showingSettings = true
        }
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("Board", selection: $appearance.themeName) {
                ForEach(BoardTheme.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Pieces", selection: $appearance.styleName) {
                ForEach(PieceStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
    }

    /// A strip shows the pieces its own side has captured, so it holds the
    /// other colour. Which side is at the bottom depends on the flip.
    private func strip(fen: String, bottom: Bool) -> CapturedStrip {
        let gone = Captured.missing(fen: fen)
        let whiteTook = Captured.value(gone.black)
        let blackTook = Captured.value(gone.white)
        let isWhite = (bottom != game.flipped)
        return CapturedStrip(taken: isWhite ? gone.black : gone.white,
                             lead: max(0, isWhite ? whiteTook - blackTook
                                                  : blackTook - whiteTook))
    }

    private var exploreBoard: some View {
        let fen = (openingDrill.active ? openingDrill.state?.fen : nil) ?? boardState.fen
        return VStack(spacing: 8) {
            VStack(spacing: 6) {
            HStack(spacing: 8) {
                // The field collapses to its icon when it is not being used.
                // Held open it took 168pt off a 416pt row and the opening's
                // name truncated to "Sicilian Defense: Naj...".
                if searching {
                    TextField("Search 3,810 openings", text: $openings.query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 200)
                        .focused($searchFocused)
                        .onSubmit { if let first = openings.results.first { openings.choose(first) } }
                    Button("Cancel") { openings.close(); searchFocused = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        openings.open()
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text(drillTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer()
                if openingDrill.active {
                    Button("Stop") { openingDrill.stop() }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if let name = boardState.openingName {
                    // Drill whatever Chichi has just put on the board.
                    Button("Drill this line") { openingDrill.start(name: name) }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 416)
            strip(fen: fen, bottom: false)
            }
            .frame(height: CardSize.aboveBoard, alignment: .bottom)

            if let drill = openingDrill.state, openingDrill.active {
                BoardView(fen: drill.fen, legal: drill.legal ?? [:],
                          flipped: game.flipped) { from, to in
                    openingDrill.play(from: from, to: to)
                }
                strip(fen: fen, bottom: true)
                drillFeedback(drill)
            } else {
                BoardView(fen: boardState.fen,
                          lastMove: boardState.currentMove,
                          flipped: game.flipped)
                    .overlay { if searching { openingResults } }
                strip(fen: fen, bottom: true)
                lineControls
            }
        }
    }

    /// Step through the line, or watch it again. The move you are on is the
    /// highlighted one: an opening is an order, not a final position.
    @ViewBuilder
    private var lineControls: some View {
        if boardState.steps.count > 1 {
            HStack(spacing: 8) {
                smallButton("Replay", systemImage: "arrow.counterclockwise") {
                    boardState.play()
                }
                smallButton("Back", systemImage: "chevron.left") { boardState.stepBack() }
                    .disabled(!boardState.canStepBack)
                    .opacity(boardState.canStepBack ? 1 : 0.35)
                smallButton("Next", systemImage: "chevron.right") { boardState.stepForward() }
                    .disabled(!boardState.canStepForward)
                    .opacity(boardState.canStepForward ? 1 : 0.35)

                // Scrolls to follow, like the Play tab's list. Without this the
                // highlighted move walks off the right-hand edge on any line
                // longer than about five moves, and the list looks broken when
                // it is only out of view.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(boardState.steps.enumerated()), id: \.offset) { i, step in
                                if let san = step.san {
                                    Text(i % 2 == 1 ? "\(i / 2 + 1). \(san)" : san)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(i == boardState.index
                                                         ? AnyShapeStyle(Color.white)
                                                         : AnyShapeStyle(.tertiary))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(i == boardState.index
                                                    ? Color.accentColor.opacity(0.55) : .clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .id(i)
                                        .onTapGesture { boardState.show(i) }
                                }
                            }
                        }
                    }
                    .onChange(of: boardState.index) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(boardState.index, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 416, alignment: .leading)
        }
    }

    /// The picker is showing when it has been opened, whatever has been typed:
    /// an empty query lists a starting selection rather than nothing.
    private var searching: Bool { openings.isOpen }

    /// Drawn over the board rather than under the field: 40 results need the
    /// space, and the board underneath is about to be replaced anyway.
    private var openingResults: some View {
        VStack(spacing: 0) {
            if openings.results.isEmpty {
                Text("Nothing matches \"\(openings.query)\".")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(openings.results) { hit in
                            Button { openings.choose(hit) } label: {
                                HStack(spacing: 8) {
                                    Text(hit.eco)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 28, alignment: .leading)
                                    Text(hit.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 416, height: 416, alignment: .top)
        // Opaque. At 0.97 the board showed through the list and made it hard
        // to read, which is the opposite of what a picker is for.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var drillTitle: String {
        if openingDrill.active, let drill = openingDrill.state {
            return "\(drill.name), \(drill.ply)/\(drill.total)"
        }
        return boardState.openingName ?? "Starting position"
    }

    @ViewBuilder
    private func drillFeedback(_ drill: OpeningDrillState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if drill.finished {
                Text(drill.wrong == 0
                     ? "Line complete, no mistakes."
                     : "Line complete, \(drill.wrong) wrong turn\(drill.wrong == 1 ? "" : "s").")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(drill.wrong == 0 ? .green : .orange)
            } else if drill.correct == false {
                Text("\(drill.youPlayed ?? "That") isn't the line. It goes \(drill.expected ?? "").")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.9))
            } else if let reply = drill.reply {
                Text("\(drill.youPlayed ?? ""). The book answers \(reply).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Play the line from memory.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(drill.movesSan.joined(separator: " "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 416, alignment: .leading)
    }

    private var playBoard: some View {
        VStack(spacing: 8) {
            VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Every status is short enough to fit beside the pickers and the
                // button: the row is 416pt and they take about 260 of it. Giving
                // this text priority instead only moved the truncation along, to
                // a "New Game" button that read "New…".
                Text(playStatusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                colourPicker
                levelPicker
                Button("New Game") {
                    chat.divider("New game")
                    game.newGame()
                }
                    .fixedSize()
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(width: 416)
            strip(fen: game.fen, bottom: false)
            }
            .frame(height: CardSize.aboveBoard, alignment: .bottom)

            BoardView(
                fen: game.fen,
                legal: game.legal,
                lastMove: game.lastMove,
                checkSquare: game.checkSquare,
                flipped: game.flipped
            ) { from, to in
                game.playMove(fromSquare: from, toSquare: to)
            }
            .overlay {
                if game.pendingPromotion != nil { promotionPicker }
                if let warning = game.warning { guardSheet(warning) }
            }
            strip(fen: game.fen, bottom: true)

            coachControls
            boardControls

            if let error = game.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The dial. Silent plays a straight game; everything else checks a move
    /// before it commits.
    private var coachControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $game.coaching) {
                    ForEach(CoachingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)

                Toggle(isOn: $game.guardEnabled) {
                    Text("Blunder guard")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            // On its own line with the full width. Squeezed in beside the dial
            // it truncated after three words, which made the hint useless.
            Text(game.coaching.help)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: 416, alignment: .leading)
    }

    /// Shown instead of playing the move. Nothing has been sent to the engine
    /// yet, so "Pick another" costs nothing and needs no takeback.
    private func guardSheet(_ warning: GuardWarning) -> some View {
        VStack(spacing: 12) {
            Text(warning.san)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text(warning.headline)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            Text("costs about \(warning.lossCp / 100).\(abs(warning.lossCp) % 100 / 10) pawns")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 10) {
                Button("Pick another") { game.reconsider() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Button("Play it anyway") { game.playAnyway() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(22)
        .background(Color.black.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var boardControls: some View {
        HStack(spacing: 8) {
            followButton
            smallButton("Flip", systemImage: "arrow.up.arrow.down") {
                game.flipped.toggle()
            }
            smallButton("Take Back", systemImage: "arrow.uturn.backward") {
                game.takeback()
            }
            .disabled(!game.canTakeBack)
            .opacity(game.canTakeBack ? 1 : 0.4)

            moveList
        }
        .frame(width: 416, alignment: .leading)
    }

    /// Offered whenever Chichi has just put an opening on the board: saying yes
    /// is a click rather than a sentence, and there is then no doubt about
    /// which line was meant.
    @ViewBuilder
    private var followButton: some View {
        if let followed = game.following {
            smallButton(followed.family, systemImage: "book.fill") { game.unfollow() }
        } else if let name = game.openingNow {
            // Where the game actually is, once a chosen line has died. Falling
            // back to the Explore tab's opening offered to follow the line that
            // had just been abandoned, one message after saying it was gone.
            smallButton(GameStore.family(name), systemImage: "book") {
                game.follow(name: name)
            }
        } else if let name = boardState.openingName {
            // Just the family. "Play French Defense" truncated to "Play French
            // D..." in this row, and the book icon already says what it is for.
            smallButton(GameStore.family(name), systemImage: "book") {
                game.follow(name: name)
            }
        }
    }

    /// The game so far, newest at the right, scrolled to follow play.
    private var moveList: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(numberedMoves.enumerated()), id: \.offset) { index, pair in
                        HStack(spacing: 4) {
                            Text("\(index + 1).")
                                .foregroundStyle(.tertiary)
                            Text(pair)
                                .foregroundStyle(.primary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(index)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: game.movesSan.count) {
                if !numberedMoves.isEmpty {
                    withAnimation { proxy.scrollTo(numberedMoves.count - 1, anchor: .trailing) }
                }
            }
        }
        .frame(height: 20)
    }

    /// SAN grouped into full moves: ["e4 e5", "Nf3 Nc6", ...]
    private var numberedMoves: [String] {
        stride(from: 0, to: game.movesSan.count, by: 2).map { index in
            let white = game.movesSan[index]
            let black = index + 1 < game.movesSan.count ? " " + game.movesSan[index + 1] : ""
            return white + black
        }
    }

    private func smallButton(_ title: String, systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// Which side you take next game. It deliberately does not disturb the game
    /// on the board: changing colour mid-game would mean resigning one, and the
    /// New Game button is right there.
    private var colourPicker: some View {
        Menu(CardView.colourLabel(game.preferredColour)) {
            ForEach(["white", "black", "random"], id: \.self) { choice in
                Button(CardView.colourLabel(choice)) { game.preferredColour = choice }
            }
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 12))
        .frame(width: 74)
    }

    private static func colourLabel(_ colour: String) -> String {
        switch colour {
        case "black":  return "\u{265A} Black"
        case "random": return "\u{2680} Random"
        default:       return "\u{2654} White"
        }
    }

    /// 1 is weakest. The engine's own weakening options bottom out well above
    /// a beginner, so this drives search depth plus a chance of the opponent
    /// simply not looking at the board.
    private var levelPicker: some View {
        Menu("Level \(game.level)") {
            ForEach(1...8, id: \.self) { value in
                // What the rung is, not just its number. The old ladder's
                // numbers meant nothing measurable, and levels 5 to 8 were one
                // strength wearing four labels; these are the two things that
                // actually vary. See LEVELS in coachd.py.
                Button("Level \(value)  \u{2014}  \(GameStore.levelBlurb(value))") {
                    game.level = value
                    game.newGame()
                }
            }
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 12))
        .frame(width: 76)
    }

    private var promotionPicker: some View {
        VStack(spacing: 10) {
            Text("Promote to")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 10) {
                ForEach([("q", "\u{2655}"), ("r", "\u{2656}"), ("b", "\u{2657}"), ("n", "\u{2658}")], id: \.0) { piece, glyph in
                    Button {
                        game.completePromotion(piece: piece)
                    } label: {
                        Text(glyph)
                            .font(.system(size: 34))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.white.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Cancel") { game.cancelPromotion() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(20)
        .background(Color.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var playStatusText: String {
        if game.awaitingCoach { return "Chichi is thinking\u{2026}" }
        switch game.status {
        case "no game yet": return "No game yet"
        case "ongoing": return "Your move"
        case "check": return "Check!"
        case "stalemate": return "Stalemate, a draw"
        // Who won is a colour; whether that is you depends on the side you took.
        case let s where s.hasPrefix("checkmate_"):
            let winner = s.hasPrefix("checkmate_white") ? "white" : "black"
            return winner == game.myColour
                ? "Checkmate, you win ♜" : "Checkmate, they win"
        case let s where s.hasPrefix("draw"): return "Draw"
        default: return game.status
        }
    }

    private func sendChat() {
        chat.send()
        chatFocused = false
    }

    private var chatPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                // `.copy("Resources")` keeps the folder, so the file sits one level
                // down; the piece sets look it up the same way.
                if let url = Bundle.module.url(forResource: "chichi-avatar", withExtension: "png",
                                               subdirectory: "Resources")
                        ?? Bundle.module.url(forResource: "chichi-avatar", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text("Chichi")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if !chat.messages.isEmpty {
                    Button("Clear") { chat.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            messageBubble(message).id(message.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: chat.messages.count) {
                    if let last = chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            HStack(spacing: 8) {
                // Dropping focus on send is not a flourish: the field keeps its
                // scroll offset after the text is cleared, so the placeholder
                // came back as "sk Chichi…" with the A scrolled out of sight.
                TextField("Ask Chichi…", text: $chat.draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($chatFocused)
                    .onSubmit { sendChat() }
                Button(action: sendChat) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(chat.isSending || chat.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        if message.isDivider {
            HStack(spacing: 8) {
                Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
                Text(message.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
            }
            .padding(.vertical, 4)
        } else {
            plainBubble(message)
        }
    }

    /// Chat text as attributed markdown, so **Nxf6+** reads as bold rather than
    /// as four literal asterisks. Inline only and whitespace-preserving: the
    /// bubble wants emphasis and paragraph breaks, not headings and lists.
    private static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func plainBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.fromUser { Spacer(minLength: 20) }
            Group {
                if message.isLoading {
                    HStack(spacing: 7) {
                        ProgressView().scaleEffect(0.5)
                        Text("Chichi is typing")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(Self.rendered(message.text))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(message.fromUser ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !message.fromUser { Spacer(minLength: 20) }
        }
    }
}
