import CoreGraphics
import Foundation

enum CardSize {
    // Wider than the other cards — needs a full board plus a chat column
    // side by side, not just a single narrow panel.
    static let width: Double = 760
    // Taller since the coaching dial arrived: board, dial, controls and the
    // move list all have to fit without the chat column shrinking.
    static let height: Double = 660
    /// Height reserved above the board in every mode that draws one, so that
    /// switching tabs cannot shift the board up or down. Each mode's header is
    /// bottom-aligned inside it and may be any height up to this.
    static let aboveBoard: CGFloat = 52
}
