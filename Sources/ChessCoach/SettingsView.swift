import SwiftUI

/// Re-imports the Lichess puzzle set at the band the linked rating implies.
///
/// It streams the whole dump rather than downloading a file, so it takes
/// minutes and cannot report a percentage. Saying "a few minutes" up front is
/// the honest version of a progress bar that would have to be invented.
@MainActor
final class PuzzleImporter: ObservableObject {
    @Published var isRunning = false
    @Published var outcome: String?

    func run(low: Int, high: Int, onFinish: @escaping () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        outcome = nil
        Task {
            let ok = await Self.shell(["import", "--min", "\(low)", "--max", "\(high)"])
            isRunning = false
            outcome = ok ? "Done." : "The import failed. Check your connection."
            onFinish()
        }
    }

    private static func shell(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Paths.python)
                process.arguments = [Paths.puzzles] + arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

/// Everything about this app that is about *you* rather than about chess.
///
/// It exists because the coach was tuned to one person in three places at
/// once: the chess.com account, the rating band the opening explorer reports,
/// and the range of puzzles worth drilling. Two of those were constants in
/// Python with that person's name in the comment. Linking an account now
/// derives all three.
struct SettingsView: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var game: GameStore
    @StateObject private var importer = PuzzleImporter()
    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var confirmingSwitch = false
    @State private var installedModels: [String] = []
    @State private var lichessToken = ""
    @State private var tokenSaved = false
    @State private var chosenModel = AppConfig.shared.model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.12))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accountSection
                    derivedSection
                    lichessSection
                    modelSection
                    playSection
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 470)
        .background(VisualEffectBackground())
        .onAppear {
            history.loadAccount()
            typed = history.account?.username ?? ""
            Task { installedModels = await Self.ollamaModels() }
        }
        // loadAccount is a subprocess away, so onAppear runs before there is
        // an account to read and the field would sit empty next to a button
        // offering to "Change" it.
        .onChange(of: history.account?.username) {
            if typed.isEmpty, let name = history.account?.username { typed = name }
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // ---------------------------------------------------------------- lichess

    /// Lichess made the opening explorer login-only in March 2026, so the advice
    /// that draws on "what do players at your rating actually play" needs a
    /// token. It is free, needs no scopes, and everything else works without it,
    /// which is why this sits here rather than in the first-launch screen.
    private var lichessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Lichess token (optional)")
            Text("Only needed for opening advice, which reads what players at your rating play. "
                 + "Make one at lichess.org/account/oauth/token with no scopes ticked.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                SecureField("lip_…", text: $lichessToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 180)
                    .onSubmit { saveToken() }
                Button("Save") { saveToken() }
                    .font(.system(size: 11))
                    .disabled(lichessToken.trimmingCharacters(in: .whitespaces).isEmpty)
                if tokenSaved {
                    Text("Saved.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func saveToken() {
        let tidied = lichessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tidied.isEmpty else { return }
        try? tidied.write(toFile: Paths.lichessToken, atomically: true, encoding: .utf8)
        // Not read back into the field: a token is write-only as far as the
        // panel is concerned, so a screen share never shows it.
        lichessToken = ""
        tokenSaved = true
    }

    // ------------------------------------------------------------------ model

    /// Which Ollama model the coach talks through.
    ///
    /// Everything Chichi is told is computed by the engine and checked before it
    /// is shown, so a weaker model writes duller sentences rather than wrong
    /// chess. That is what makes this safe to expose at all. It is still a real
    /// choice: 8 GB of model is a lot to ask of a laptop, and somebody on a
    /// lighter Mac would rather have a smaller coach than none.
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Coach model")
            Text("Tested on gemma4:12b, which is what Rookie downloads. Smaller models "
                 + "will run on less memory and give you a blunter coach; the chess itself "
                 + "is worked out by the engine either way.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Picker("", selection: $chosenModel) {
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: chosenModel) {
                    guard chosenModel != AppConfig.shared.model else { return }
                    AppConfig.setModel(chosenModel)
                }
                if installedModels.isEmpty {
                    Text("Ollama isn't answering")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            if !installedModels.contains(chosenModel) {
                Text("\(chosenModel) isn't installed. Run ollama pull \(chosenModel) in Terminal, "
                     + "or pick one of the installed ones.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The installed models, plus whatever is configured even if it is not
    /// installed, so the picker never silently drops the current setting.
    private var modelChoices: [String] {
        var out = installedModels
        if !out.contains(chosenModel) { out.insert(chosenModel, at: 0) }
        return out
    }

    private static func ollamaModels() async -> [String] {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return (object["models"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
            .sorted()
    }

    // ---------------------------------------------------------------- account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("chess.com account")
            Text("Your games are read from the public API. No password, and nothing is sent anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("username", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 180)
                    .onSubmit { attemptLink() }
                Button(history.account?.username == nil ? "Link" : "Change") { attemptLink() }
                    .font(.system(size: 11))
                    .disabled(history.isLinking || typed.trimmingCharacters(in: .whitespaces).isEmpty)
                if history.isLinking { ProgressView().scaleEffect(0.45).frame(width: 14) }
            }

            // Switching accounts deletes the last one's games and the puzzles
            // built from their blunders. That is the right behaviour — a review
            // of two players describes neither — but it is not the sort of
            // thing to do quietly.
            if confirmingSwitch, let current = history.account {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Linking a different account will delete "
                         + "\(current.games ?? 0) imported games and "
                         + "\(current.ownPuzzles ?? 0) puzzles built from your blunders.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Delete and link") {
                            confirmingSwitch = false
                            history.link(typed)
                        }
                        .font(.system(size: 11))
                        Button("Cancel") {
                            confirmingSwitch = false
                            typed = history.account?.username ?? ""
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let error = history.linkError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            } else if let outcome = history.linkOutcome {
                Text(outcome)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func attemptLink() {
        let wanted = typed.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return }
        let current = history.account?.username
        if let current, current.lowercased() != wanted.lowercased(),
           (history.account?.games ?? 0) > 0 {
            confirmingSwitch = true
        } else {
            history.link(wanted)
        }
    }

    // ---------------------------------------------------------------- derived

    @ViewBuilder
    private var derivedSection: some View {
        if let account = history.account, account.username != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Set from your rating")
                Text("These were one person's numbers, hardcoded. They now come from the account above.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                row("Your rating", ratingSummary(account))
                row("Openings shown for", "players rated \(account.explorerBands.replacingOccurrences(of: ",", with: ", "))")
                row("Puzzles worth drilling", "\(account.puzzleBand.first ?? 0)–\(account.puzzleBand.last ?? 0)")

                // The band can move without the stored puzzles moving with it,
                // and a drill set aimed at somebody else's rating is the whole
                // problem this panel exists to fix.
                if let stale = account.lichessOutOfBand, stale > 0 {
                    Text("\(stale) of your \(account.lichessPuzzles ?? 0) stored puzzles sit outside that band.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(importer.isRunning ? "Importing…" : "Re-import puzzles") {
                            importer.run(low: account.puzzleBand.first ?? 400,
                                         high: account.puzzleBand.last ?? 1300) {
                                history.loadAccount()
                            }
                        }
                        .font(.system(size: 11))
                        .disabled(importer.isRunning)
                        if importer.isRunning {
                            Text("a few minutes")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else if let outcome = importer.outcome {
                            Text(outcome)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func ratingSummary(_ account: AccountInfo) -> String {
        var parts: [String] = []
        for (key, label) in [("rapid", "rapid"), ("blitz", "blitz"), ("bullet", "bullet")] {
            if let value = account.ratings[key] { parts.append("\(value) \(label)") }
        }
        if let tactics = account.tactics { parts.append("\(tactics) tactics") }
        return parts.isEmpty ? "not rated yet" : parts.joined(separator: ", ")
    }

    // ------------------------------------------------------------------- play

    private var playSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Play")
            Picker("Side", selection: $game.preferredColour) {
                Text("White").tag("white")
                Text("Black").tag("black")
                Text("Random").tag("random")
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            Text("Applies to your next new game, not the one on the board.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // ----------------------------------------------------------------- pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
