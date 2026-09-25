import AppKit
import SwiftUI

/// Real vibrancy behind the window's content: the windowed family's background,
/// shared file-for-file with Nib and snom-bot. It replaced a flat near-black
/// fill that gave this app no light mode and forced every foreground to be
/// white at some opacity. An NSVisualEffectView follows the system appearance
/// for free, which is what a .regular app with a Dock icon is expected to do.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
