import SwiftUI

/// What each side has taken, worked out by counting a full set against what the
/// FEN still shows. There is exactly one right answer, so it is counted rather
/// than tracked: a move list can be replayed wrong, a position cannot be.
enum Captured {
    static let values: [Character: Int] = ["q": 9, "r": 5, "b": 3, "n": 3, "p": 1]
    private static let fullSet: [Character: Int] = ["q": 1, "r": 2, "b": 2, "n": 2, "p": 8]
    /// Heaviest first, so a strip reads like a scoresheet rather than a jumble.
    private static let order: [Character] = ["q", "r", "b", "n", "p"]

    /// Pieces of each colour that are no longer on the board.
    ///
    /// A promotion is counted honestly rather than cleverly: the pawn shows as
    /// lost, and the extra queen simply means no queen was ever captured, which
    /// is what `max(0,)` says. Every board site has this same quirk.
    static func missing(fen: String) -> (white: [Character], black: [Character]) {
        let placement = fen.split(separator: " ").first.map(String.init) ?? fen
        var white: [Character: Int] = [:]
        var black: [Character: Int] = [:]
        for ch in placement where ch.isLetter {
            let kind = Character(ch.lowercased())
            if ch.isUppercase { white[kind, default: 0] += 1 } else { black[kind, default: 0] += 1 }
        }
        func gone(_ left: [Character: Int], uppercase: Bool) -> [Character] {
            var out: [Character] = []
            for kind in order {
                let lost = max(0, (fullSet[kind] ?? 0) - (left[kind] ?? 0))
                let ch = uppercase ? Character(kind.uppercased()) : kind
                out.append(contentsOf: Array(repeating: ch, count: lost))
            }
            return out
        }
        // Each entry is a piece that is gone, drawn in its own colour. A side's
        // strip therefore shows the other colour's missing pieces.
        return (white: gone(white, uppercase: true), black: gone(black, uppercase: false))
    }

    static func value(_ pieces: [Character]) -> Int {
        pieces.reduce(0) { $0 + (values[Character($1.lowercased())] ?? 0) }
    }
}

/// One player's haul: the pieces they have captured, and by how much they lead.
/// Fixed height, always present even when empty, because a strip that appears
/// only after the first capture would shove the board down mid-game.
struct CapturedStrip: View {
    static let height: CGFloat = 20
    let taken: [Character]
    let lead: Int

    var body: some View {
        HStack(spacing: -3) {
            ForEach(Array(taken.enumerated()), id: \.offset) { _, piece in
                PieceView(piece: piece, size: 15)
                    .frame(width: 13, height: CapturedStrip.height)
            }
            if lead > 0 {
                Text("+\(lead)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 7)
            }
            Spacer()
        }
        .frame(width: 416, height: CapturedStrip.height, alignment: .leading)
    }
}
