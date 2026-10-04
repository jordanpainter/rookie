import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let boardState = BoardState()
    private let chat = ChatStore()
    private let game = GameStore()
    private let history = HistoryStore()
    private let drill = DrillStore()
    private let endgame = EndgameStore()
    private let appearance = Appearance()
    private let openingDrill = OpeningDrillStore()
    private let openings = OpeningSearch()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        boardState.start()
        game.loadSettings()
        game.loadState()
        // Wake Chichi now rather than on the first coached move. Cold, his
        // first turn takes 25 to 30 seconds; warm it is 5 to 10. Nothing to
        // wake if he is muted.
        if game.coaching.usesModel { chat.warmUp() }

        let size = CGSize(width: CardSize.width, height: CardSize.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rookie"
        window.center()
        window.setFrameAutosaveName("ChessCoach.mainWindow")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: RootView()
                .environmentObject(self.boardState)
                .environmentObject(self.chat)
                .environmentObject(self.game)
                .environmentObject(self.history)
                .environmentObject(self.drill)
                .environmentObject(self.endgame)
                .environmentObject(self.appearance)
                .environmentObject(self.openingDrill)
                .environmentObject(self.openings)
        )
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The standard menus. Without an Edit menu, Cmd+C and Cmd+V do nothing in a
    /// text field, because macOS routes them through the menu's key equivalents:
    /// a new user could not paste their chess.com username. Without the rest,
    /// Cmd+Q, Cmd+W and Cmd+, do nothing either.
    private func installMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Rookie",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Rookie", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others",
                                 action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Rookie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "Rookie", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    /// The settings sheet belongs to the SwiftUI view, so the menu asks for it
    /// rather than owning it.
    @objc private func showSettings() {
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }
}

extension Notification.Name {
    static let showSettings = Notification.Name("RookieShowSettings")
}
