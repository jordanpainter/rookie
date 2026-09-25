import AppKit
import SwiftUI

/// Board and piece looks, remembered between launches.
///
/// Purely presentational: nothing here can change what a move means, so the
/// themes are free to be as loud as you like.
@MainActor
final class Appearance: ObservableObject {
    @AppStorage("boardTheme") var themeName: String = BoardTheme.classic.rawValue {
        willSet { objectWillChange.send() }
    }
    @AppStorage("pieceStyle") var styleName: String = PieceStyle.chessnut.rawValue {
        willSet { objectWillChange.send() }
    }

    var theme: BoardTheme { BoardTheme(rawValue: themeName) ?? .classic }
    /// A stored style that no longer exists, such as the old glyph styles,
    /// falls back to the default rather than to nothing.
    var style: PieceStyle { PieceStyle(rawValue: styleName) ?? .chessnut }
}

/// Drawn piece sets, each a folder of twelve files in `Resources/pieces/`.
///
/// The two Unicode glyph styles were dropped: they looked like a font, because
/// they are one. Glyphs survive only as the fallback in `PieceView` if a set is
/// ever missing a file. Who drew each set, and its licence, is in `NOTICE.md`,
/// which ships inside the app; the menu shows names only.
enum PieceStyle: String, CaseIterable, Identifiable {
    case doodle, chessnut, rhosgfx, celtic, fantasy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doodle:   return "Doodle"
        case .rhosgfx:  return "Rhos"
        case .celtic:   return "Celtic"
        case .fantasy:  return "Fantasy"
        case .chessnut: return "Chessnut"
        }
    }

    var folder: String { rawValue }
}

/// Loads and caches the bundled piece images.
///
/// SVG first, which NSImage renders natively and stays sharp at any size; PNG
/// otherwise, because hand-drawn sets come out of apps like Procreate that
/// cannot export SVG. Files are named `wK`, `bQ` and so on. Cached because a
/// board redraw asks for up to 32 of them.
enum PieceImages {
    private static var cache: [String: NSImage] = [:]

    static func image(set: String, piece: Character) -> NSImage? {
        let colour = piece.isUppercase ? "w" : "b"
        let name = "\(colour)\(piece.uppercased())"
        let key = "\(set)/\(name)"
        if let hit = cache[key] { return hit }
        let found = ["svg", "png"].lazy.compactMap { ext in
            Bundle.module.url(forResource: name, withExtension: ext,
                              subdirectory: "Resources/pieces/\(set)")
                ?? Bundle.module.url(forResource: name, withExtension: ext,
                                     subdirectory: "pieces/\(set)")
        }.first
        guard let url = found, let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}

enum BoardTheme: String, CaseIterable, Identifiable {
    case glass, classic, forest, ocean, slate, walnut, contrast

    /// The glass board is a frosted pane over the window's own translucent
    /// background, so it takes its colour from the desktop behind it and follows
    /// light and dark mode. The others are painted.
    var isGlass: Bool { self == .glass }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass:    return "Glass"
        case .classic:  return "Classic"
        case .forest:   return "Forest"
        case .ocean:    return "Ocean"
        case .slate:    return "Slate"
        case .walnut:   return "Walnut"
        case .contrast: return "High contrast"
        }
    }

    var light: Color {
        switch self {
        case .glass:    return Color.white.opacity(0.16)
        case .classic:  return Color(red: 0.93, green: 0.89, blue: 0.80)
        case .forest:   return Color(red: 0.93, green: 0.93, blue: 0.82)
        case .ocean:    return Color(red: 0.87, green: 0.89, blue: 0.90)
        case .slate:    return Color(red: 0.90, green: 0.90, blue: 0.91)
        case .walnut:   return Color(red: 0.87, green: 0.76, blue: 0.60)
        case .contrast: return Color(red: 0.98, green: 0.98, blue: 0.98)
        }
    }

    var dark: Color {
        switch self {
        case .glass:    return Color.black.opacity(0.24)
        case .classic:  return Color(red: 0.46, green: 0.32, blue: 0.24)
        case .forest:   return Color(red: 0.46, green: 0.59, blue: 0.34)
        case .ocean:    return Color(red: 0.42, green: 0.55, blue: 0.64)
        case .slate:    return Color(red: 0.44, green: 0.48, blue: 0.55)
        case .walnut:   return Color(red: 0.55, green: 0.36, blue: 0.20)
        case .contrast: return Color(red: 0.22, green: 0.24, blue: 0.27)
        }
    }

    /// Highlights are tinted per theme so they stay visible on both squares
    /// rather than vanishing into a light one.
    var lastMove: Color {
        switch self {
        case .ocean, .slate:  return Color(red: 0.35, green: 0.62, blue: 0.85).opacity(0.38)
        case .contrast, .glass: return Color.blue.opacity(0.30)
        default:              return Color.yellow.opacity(0.28)
        }
    }

    var selection: Color {
        switch self {
        case .ocean, .slate:  return Color(red: 0.30, green: 0.60, blue: 0.88).opacity(0.55)
        case .contrast, .glass: return Color.blue.opacity(0.45)
        default:              return Color.yellow.opacity(0.48)
        }
    }
}
