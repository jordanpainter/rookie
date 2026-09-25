import SwiftUI

/// A move worth drawing attention to.
struct MoveHighlight: Equatable {
    let from: String
    let to: String
}

/// Parses the board-placement field of a FEN into square name -> piece letter.
/// Keying by name rather than by grid position keeps flipping trivial: only the
/// drawing order changes, never the lookup.
private func piecesBySquare(_ fen: String) -> [String: Character] {
    let placement = fen.split(separator: " ").first.map(String.init) ?? fen
    var pieces: [String: Character] = [:]
    for (rowIndex, row) in placement.split(separator: "/").enumerated() {
        let rank = 8 - rowIndex
        var file = 0
        for ch in row {
            if let empty = ch.wholeNumberValue {
                file += empty
            } else {
                if file < 8, let scalar = UnicodeScalar(97 + file) {
                    pieces["\(Character(scalar))\(rank)"] = ch
                }
                file += 1
            }
        }
    }
    return pieces
}

private enum BoardColors {
    static let check = Color.red.opacity(0.55)
    static let hint = Color.black.opacity(0.22)
}

struct BoardView: View {
    let fen: String
    /// from-square -> squares it may legally move to. Comes straight from the
    /// engine, so the board never decides legality itself.
    var legal: [String: [String]] = [:]
    var lastMove: MoveHighlight?
    var checkSquare: String?
    var flipped = false
    /// Non-nil makes the board interactive. Called with (from, to).
    var onMove: ((String, String) -> Void)?

    @EnvironmentObject private var appearance: Appearance
    @State private var selected: String?
    @State private var dragFrom: String?
    @State private var dragPoint: CGPoint?
    @State private var isDragging = false

    private let squareSize: CGFloat = 52
    private var boardSize: CGFloat { squareSize * 8 }

    private var pieces: [String: Character] { piecesBySquare(fen) }
    private var targets: [String] { selected.flatMap { legal[$0] } ?? [] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            grid
            if let from = dragFrom, let point = dragPoint, isDragging,
               let piece = pieces[from] {
                // The piece follows the cursor, rather than sitting on its old
                // square while an invisible thing gets dragged.
                pieceView(piece, size: squareSize * 0.8)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                    .position(point)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: boardSize, height: boardSize)
        .coordinateSpace(name: "board")
        // Glass only: a frosted pane under the tinted squares, so the board is
        // one sheet of glass rather than 64 separate blurs.
        .background { if appearance.theme.isGlass { Rectangle().fill(.ultraThinMaterial) } }
        .overlay { if appearance.theme.isGlass { glassSheen } }
        .clipShape(RoundedRectangle(cornerRadius: appearance.theme.isGlass ? 12 : 6))
        .overlay(RoundedRectangle(cornerRadius: appearance.theme.isGlass ? 12 : 6)
            .stroke(appearance.theme.isGlass ? Color.white.opacity(0.35) : Color.primary.opacity(0.15),
                    lineWidth: 1))
        .gesture(dragGesture)
    }

    /// Light catching the top of the pane. Faint on purpose: it has to read as
    /// glass without washing out the pieces under it.
    private var glassSheen: some View {
        LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.0)],
                       startPoint: .top, endPoint: .center)
            .allowsHitTesting(false)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { file in
                        square(rank: rank, file: file)
                    }
                }
            }
        }
    }

    private func square(rank: Int, file: Int) -> some View {
        let name = squareName(rank: rank, file: file)
        let isLight = (rank + file).isMultiple(of: 2)
        let piece = pieces[name]
        let isTarget = targets.contains(name)

        return ZStack {
            Rectangle().fill(isLight ? appearance.theme.light : appearance.theme.dark)

            if name == lastMove?.from || name == lastMove?.to {
                Rectangle().fill(appearance.theme.lastMove)
            }
            if name == checkSquare {
                Rectangle().fill(BoardColors.check)
            }
            if name == selected {
                Rectangle().fill(appearance.theme.selection)
            }

            if let piece, !(isDragging && name == dragFrom) {
                pieceView(piece, size: squareSize * 0.72)
            }

            // A dot for a quiet move, a ring for a capture: the shape says
            // whether something is already standing there.
            if isTarget {
                if piece == nil {
                    Circle().fill(BoardColors.hint).frame(width: squareSize * 0.28)
                } else {
                    Circle().stroke(BoardColors.hint, lineWidth: 4)
                        .frame(width: squareSize * 0.82)
                }
            }

            coordinate(name: name, rank: rank, file: file, isLight: isLight)
        }
        .frame(width: squareSize, height: squareSize)
        .contentShape(Rectangle())
        .onTapGesture { if onMove != nil { handleTap(name) } }
    }

    /// Draws one piece in the chosen style.
    ///
    @ViewBuilder
    private func pieceView(_ piece: Character, size: CGFloat) -> some View {
        PieceView(piece: piece, size: size)
    }

    /// File letters along the bottom edge, rank numbers down the left, drawn in
    /// the opposite square colour so they stay legible on both.
    private func coordinate(name: String, rank: Int, file: Int, isLight: Bool) -> some View {
        // Glass squares are nearly transparent, so borrowing the opposite
        // square's colour left the labels invisible on the light ones.
        let ink = appearance.theme.isGlass
            ? Color.primary.opacity(0.45)
            : (isLight ? appearance.theme.dark : appearance.theme.light).opacity(0.75)
        return ZStack {
            if file == 0 {
                Text(name.suffix(1))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 3).padding(.top, 2)
            }
            if rank == 7 {
                Text(name.prefix(1))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 3).padding(.bottom, 2)
            }
        }
    }

    // MARK: - geometry

    /// Grid cell to square name. Flipping only changes this one mapping.
    private func squareName(rank: Int, file: Int) -> String {
        let rankNumber = flipped ? rank : 7 - rank
        let fileIndex = flipped ? 7 - file : file
        let letter = Character(UnicodeScalar(97 + fileIndex)!)
        return "\(letter)\(rankNumber + 1)"
    }

    private func square(at point: CGPoint) -> String? {
        guard point.x >= 0, point.y >= 0, point.x < boardSize, point.y < boardSize else { return nil }
        return squareName(rank: Int(point.y / squareSize), file: Int(point.x / squareSize))
    }

    // MARK: - input

    /// Drag-and-drop only. Taps are handled per square by `onTapGesture`, and
    /// the minimum distance keeps the two apart: a click never starts a drag,
    /// so the gesture recogniser never has to choose between them.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("board"))
            .onChanged { value in
                guard onMove != nil else { return }
                if dragFrom == nil, let start = square(at: value.startLocation),
                   pieces[start] != nil {
                    dragFrom = start
                    selected = start
                }
                if dragFrom != nil {
                    isDragging = true
                    dragPoint = value.location
                }
            }
            .onEnded { value in
                defer { dragFrom = nil; dragPoint = nil; isDragging = false }
                guard onMove != nil, let from = dragFrom else { return }
                if let to = square(at: value.location), from != to {
                    onMove?(from, to)
                    selected = nil
                }
            }
    }

    private func handleTap(_ name: String) {
        if let from = selected {
            if from == name {
                selected = nil
            } else if legal[from]?.contains(name) == true {
                onMove?(from, name)
                selected = nil
            } else {
                // Tapping another of your own pieces reselects rather than
                // firing a move the engine would only reject.
                selected = pieces[name] != nil ? name : nil
            }
        } else if pieces[name] != nil {
            selected = name
        }
    }
}
