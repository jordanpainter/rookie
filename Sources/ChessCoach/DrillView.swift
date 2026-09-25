import SwiftUI

/// Puzzles, spaced. Two sets: the Lichess public collection filtered to your
/// band, and every blunder you actually played, which is the set that matters.
struct DrillView: View {
    @EnvironmentObject var drill: DrillStore
    @EnvironmentObject var endgame: EndgameStore

    var body: some View {
        VStack(spacing: 8) {
            header
            if drill.source.isPuzzle {
                board
                outcome
            } else {
                EndgameDrillView()
            }
        }
        .frame(width: 416)
        .onAppear {
            if drill.source.isPuzzle { drill.loadIfNeeded() } else { endgame.loadIfNeeded() }
            // The tally is shown for every source, so it loads for every source.
            drill.refreshStats()
        }
        // A finished endgame is recorded by the daemon; ask again so the day's
        // count includes it without waiting for a tab change.
        .onChange(of: endgame.state?.status) {
            if endgame.state?.isOver == true { drill.refreshStats() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $drill.source) {
                ForEach(DrillSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .onChange(of: drill.source) {
                if drill.source.isPuzzle { drill.next() } else { endgame.loadIfNeeded() }
                drill.refreshStats()
            }

            Spacer()

            // Today, and only this source. It used to be one lifetime figure
            // across all of them, so a puzzle failed days ago followed you
            // around and a good session at endgames was invisible.
            if let day = drill.stats?.today[drill.source.wire] {
                Text(day.attempted == 0
                     ? "none today"
                     : "\(day.solved)/\(day.attempted) today")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 416, height: CardSize.aboveBoard - 26, alignment: .bottom)
    }

    @ViewBuilder
    private var board: some View {
        if let puzzle = drill.puzzle {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(puzzle.turn == "white" ? "White to play" : "Black to play")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let rating = puzzle.rating {
                        Text("· rated \(rating)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    if puzzle.isOwn {
                        Text("· from your own game")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                    Spacer()
                }
                .frame(height: 20, alignment: .bottom)
                // Flipped so the side to move is always at the bottom: you are
                // solving from their seat, not reading a diagram.
                BoardView(fen: puzzle.positionFen,
                          legal: puzzle.legal ?? [:],
                          flipped: puzzle.turn == "black") { from, to in
                    drill.attempt(from: from, to: to)
                }
            }
        } else if drill.isLoading {
            ProgressView().scaleEffect(0.7).frame(height: 416)
        } else {
            Text(drill.errorMessage ?? "No puzzle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(height: 416)
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if let result = drill.result {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: result.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.correct ? .green : .orange)
                    Text(result.correct ? "Correct" : "Not this time")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Next") { drill.next() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if result.alsoGood == true, let best = result.answerSan {
                    // Counted as right, but worth knowing what the first choice was.
                    Text("Just as good. The top move was \(best).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !result.correct {
                    Text(detail(for: result))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: 416)
        } else {
            Text("Find the best move.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 416, alignment: .leading)
        }
    }

    private func detail(for result: PuzzleResult) -> String {
        var parts: [String] = []
        if let mine = result.yourMoveSan { parts.append("You played \(mine).") }
        if let answer = result.answerSan { parts.append("The move was \(answer).") }
        // Only your own blunders carry this: it is the same mistake, twice.
        if let before = result.playedBefore {
            parts.append("In the real game you played \(before) here too.")
        }
        return parts.joined(separator: " ")
    }
}
