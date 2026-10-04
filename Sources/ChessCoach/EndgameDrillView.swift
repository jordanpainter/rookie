import SwiftUI

/// Endgame drills against the Syzygy tablebase. The defence is not strong, it is
/// perfect: there is a known best move and a known distance to mate, so the drill
/// can tell you whether you are converting cleanly or just eventually.
struct EndgameDrillView: View {
    @EnvironmentObject var endgame: EndgameStore

    var body: some View {
        VStack(spacing: 8) {
            controls
            if let state = endgame.state {
                BoardView(fen: state.fen,
                          legal: state.legal ?? [:],
                          lastMove: state.lastMove.map { MoveHighlight(from: $0.from, to: $0.to) },
                          checkSquare: state.checkSquare) { from, to in
                    endgame.play(from: from, to: to)
                }
                progress(state)
            } else if endgame.isThinking {
                ProgressView().scaleEffect(0.7).frame(height: 416)
            } else {
                Text(endgame.errorMessage ?? "No drill loaded")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 416)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $endgame.selected) {
                ForEach(endgame.drills) { Text($0.name).tag($0.key) }
            }
            .labelsHidden()
            .frame(width: 220)
            .onChange(of: endgame.selected) { endgame.newPosition() }

            Button("New position") { endgame.newPosition() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
        .frame(width: 416, alignment: .leading)
    }

    @ViewBuilder
    private func progress(_ state: EndgameState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.isOver {
                Text(verdict(state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.status == "checkmate" ? .green : .orange)
            } else {
                HStack(spacing: 10) {
                    if let target = state.targetPlies {
                        Text("Mate in \(moves(target)) with perfect play")
                            .foregroundStyle(.secondary)
                    }
                    if state.yourPlies > 0 {
                        Text("· your moves: \(state.yourPlies)")
                            .foregroundStyle(.tertiary)
                        Text("· fastest \(state.optimalMoves) of \(state.yourPlies)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11))
            }

            if let played = state.youPlayed {
                if state.wasOptimal == true {
                    Text("\(played), the fastest move.")
                        .font(.system(size: 11))
                        .foregroundStyle(.green.opacity(0.85))
                } else {
                    Text("\(played), still winning, but \(state.bestWas ?? "another move") mates sooner.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.85))
                }
            }
        }
        .frame(width: 416, alignment: .leading)
    }

    private func moves(_ plies: Int) -> String {
        let full = (plies + 1) / 2
        return "\(full) move\(full == 1 ? "" : "s")"
    }

    private func verdict(_ state: EndgameState) -> String {
        switch state.status {
        case "checkmate":
            let optimal = state.targetPlies.map { " Perfect play needed \(moves($0))." } ?? ""
            return "Mated in \(state.yourPlies) moves.\(optimal)"
        case "stalemate":
            return "Stalemate. The win is gone: give the king a square."
        case "drawn_no_material":
            return "You lost the winning piece. Drawn."
        default:
            return state.status
        }
    }
}
