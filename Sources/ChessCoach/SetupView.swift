import SwiftUI

/// One line of the first-launch checklist: where it is up to, and the one
/// button that moves it on.
///
/// A view rather than a function that returns one. As a `@ViewBuilder` func
/// taking an optional tuple of an async closure, it crashed the Swift compiler
/// outright.
private struct SetupRow: View {
    let title: String
    let state: SetupStore.State
    /// Shown while the step has not been done yet.
    let waiting: String
    let actionTitle: String
    let action: () async -> Void
    @Binding var busy: Bool

    private var needsDoing: Bool {
        switch state {
        case .missing, .failed: return true
        default: return false
        }
    }

    private var detail: String {
        switch state {
        case .checking: return "Checking…"
        case .missing: return waiting
        case .working(let what, _): return what
        case .ready(let what): return what
        case .failed(let why): return why
        case .unsure(let why): return why
        }
    }

    private var fraction: Double? {
        if case .working(_, let value) = state { return value }
        return nil
    }

    private var isWorking: Bool {
        if case .working = state { return true }
        if case .checking = state { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .working = state {
                    ProgressView(value: fraction ?? 0, total: 1)
                        .progressViewStyle(.linear)
                        .opacity(fraction == nil ? 0.4 : 1)
                        .frame(maxWidth: 320)
                }
            }
            Spacer(minLength: 8)
            if needsDoing && !actionTitle.isEmpty {
                Button(actionTitle) {
                    Task {
                        busy = true
                        await action()
                        busy = false
                    }
                }
                .disabled(busy)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isWorking {
            ProgressView().controlSize(.small)
        } else if case .ready = state {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if case .failed = state {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

/// What a stranger sees the first time they open Rookie.
///
/// Nothing here is mandatory: a game against the engine works without any of
/// it, so "Skip for now" goes straight to the board.
struct SetupView: View {
    @ObservedObject var setup: SetupStore
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setting up Rookie")
                .font(.system(size: 22, weight: .semibold))
            Text("You can play a game right now. These downloads turn on the coach, the "
                 + "opening explorer and the puzzles.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SetupRow(title: "Ollama",
                     state: setup.ollama,
                     waiting: setup.ollamaInstalled
                        ? "Installed, but not answering. Open Ollama, then check again."
                        : "Not found. It runs the model on your own Mac, and it is free.",
                     actionTitle: setup.ollamaInstalled ? "" : "Get Ollama",
                     action: { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) },
                     busy: $busy)

            SetupRow(title: "The coach's model",
                     state: setup.model,
                     waiting: "\(AppConfig.shared.model), about 8 GB. Downloaded once.",
                     actionTitle: "Download",
                     action: { await setup.pullModel() },
                     busy: $busy)

            SetupRow(title: "Opening list",
                     state: setup.openings,
                     waiting: "3,300 named openings, for the Explore tab. A few seconds.",
                     actionTitle: "Fetch",
                     action: { await setup.importOpenings() },
                     busy: $busy)

            SetupRow(title: "Puzzles",
                     state: setup.puzzles,
                     waiting: "Tactics from the Lichess set, filtered to a beginner's rating. "
                        + "A few minutes.",
                     actionTitle: "Fetch",
                     action: { await setup.importPuzzles() },
                     busy: $busy)

            HStack {
                Button("Check again") {
                    Task {
                        busy = true
                        await setup.checkAll()
                        busy = false
                    }
                }
                .disabled(busy)
                Spacer()
                Button(setup.isComplete ? "Start playing" : "Skip for now") {
                    setup.dismissed = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The window's contents: the checklist until it is done or waved away, then
/// the app itself.
///
/// The check runs before anything is drawn, so somebody whose install is
/// already complete never sees the screen at all, and nobody watches the app
/// appear and then get replaced by a checklist.
struct RootView: View {
    @StateObject private var setup = SetupStore()
    @AppStorage("setupSeen") private var seen = false

    var body: some View {
        Group {
            if !setup.decided {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if seen || setup.dismissed {
                CardView()
            } else {
                SetupView(setup: setup)
                    .onChange(of: setup.dismissed) {
                        if setup.dismissed { seen = true }
                    }
            }
        }
        .task {
            guard !setup.decided else { return }
            // Before anything is asked of it, make sure the daemon holding the
            // socket is this build's, not one left over from an older one.
            await Task.detached(priority: .userInitiated) { CoachClient.restartIfStale() }.value
            if seen {
                setup.decided = true
                return
            }
            // Don't hold an empty window on a slow check. Starting the engine
            // for the first time can take twenty seconds, and until this was
            // bounded the app showed nothing but a spinner for all of it.
            let check = Task { await setup.checkAll() }
            let impatience = Task {
                try? await Task.sleep(for: .seconds(4))
                setup.decided = true
            }
            await check.value
            impatience.cancel()
            // Nothing the app can fix: there is nothing to set up, so say
            // nothing. That covers both a complete install and one it could not
            // read, which is not the same as an empty one.
            if !setup.needsAttention { seen = true }
            setup.decided = true
        }
    }
}
