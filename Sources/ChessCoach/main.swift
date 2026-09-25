import Cocoa

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Deliberately .regular, not .accessory — this is its own real app
    // (Dock icon, Cmd+Tab, a real resizable window), not a desktop card
    // like the other apps in this family.
    app.setActivationPolicy(.regular)
    app.run()
}
