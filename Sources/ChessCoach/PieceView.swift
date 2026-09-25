import SwiftUI

/// The hollow glyphs. Used for White in the outline style, and layered over a
/// filled white piece in the solid style to give it an edge.
let outlineGlyphs: [Character: String] = [
    "K": "\u{2654}", "Q": "\u{2655}", "R": "\u{2656}",
    "B": "\u{2657}", "N": "\u{2658}", "P": "\u{2659}",
]

/// The filled glyphs, one per piece type regardless of colour.
let filledGlyphs: [Character: String] = [
    "K": "\u{265A}", "Q": "\u{265B}", "R": "\u{265C}",
    "B": "\u{265D}", "N": "\u{265E}", "P": "\u{265F}",
    "k": "\u{265A}", "q": "\u{265B}", "r": "\u{265C}",
    "b": "\u{265D}", "n": "\u{265E}", "p": "\u{265F}",
]

/// One piece, drawn in whatever style is selected. Lives on its own because the
/// board is no longer the only thing that draws pieces: the captured strips do
/// too, and two copies of this would drift the moment a style was added.
struct PieceView: View {
    @EnvironmentObject var appearance: Appearance
    let piece: Character
    let size: CGFloat

    var body: some View {
        if let image = PieceImages.image(set: appearance.style.folder, piece: piece) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.16, height: size * 1.16)
        } else {
            glyph
        }
    }

    /// Only drawn if a set is missing a file, so a broken set still shows a
    /// playable board. The hollow glyph layered over the filled one gives the
    /// white piece an edge: they are the same drawing in the Unicode block.
    @ViewBuilder
    private var glyph: some View {
        let isWhite = piece.isUppercase
        ZStack {
            Text(filledGlyphs[piece] ?? "")
                .foregroundStyle(isWhite ? Color.white : Color(white: 0.11))
            if isWhite, let edge = outlineGlyphs[Character(piece.uppercased())] {
                Text(edge).foregroundStyle(Color(white: 0.11))
            }
        }
        .font(.system(size: size))
        .shadow(color: .black.opacity(0.30), radius: 1, y: 1)
    }
}
