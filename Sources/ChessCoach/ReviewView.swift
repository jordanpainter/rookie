import SwiftUI

/// Where the rating actually goes, across every game on record.
struct ReviewView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var username = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusBar
            content
        }
        .frame(width: 416)
        .onAppear { history.loadIfNeeded() }
    }

    /// Says when it last looked and lets you make it look again. Without this
    /// the tab was frozen at whatever had been imported by hand, with nothing
    /// on screen admitting it.
    private var statusBar: some View {
        HStack(spacing: 8) {
            if history.isUpdating {
                // With no report yet the middle of the tab carries the progress
                // at full size; saying it twice there is noise.
                if let progress = history.progress, history.stats != nil {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text(ReviewView.describe(progress))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                    Text("Checking chess.com for new games")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let count = history.imported {
                Text(count == 0 ? "Up to date."
                     : "Added \(count) new game\(count == 1 ? "" : "s").")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { history.refresh() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(history.isUpdating)
                .opacity(history.isUpdating ? 0.4 : 1)
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if history.needsUsername {
                centred {
                    VStack(spacing: 8) {
                        Text("Which chess.com account is yours?")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Your games are read from the public API. Nothing is sent anywhere.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                        Text("Your rating also sets which openings you are shown and which puzzles you are given.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                        HStack(spacing: 6) {
                            TextField("username", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .frame(width: 180)
                                .onSubmit { history.link(username) }
                            Button("Use this") { history.link(username) }
                                .font(.system(size: 11))
                                .disabled(history.isLinking)
                        }
                    }
                }
            } else if let stats = history.stats {
                report(stats)
            } else if history.isLoading {
                // The first link is the long one, so it gets the full-size
                // version of the same progress, where the report will appear.
                centred {
                    if let progress = history.progress {
                        VStack(spacing: 10) {
                            Text(progress.stage == .fetching ? "Fetching your games"
                                                             : "Analysing your games")
                                .font(.system(size: 13, weight: .semibold))
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                                .frame(width: 260)
                            Text(ReviewView.describe(progress))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text("Only the first time takes this long. After that it's just your new games.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)
                        }
                    } else {
                        ProgressView().scaleEffect(0.7)
                    }
                }
            } else if let error = history.errorMessage {
                centred {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            } else {
                centred { Text("No history yet").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }

    static func describe(_ progress: HistoryStore.UpdateProgress) -> String {
        switch progress.stage {
        case .fetching:
            return "Month \(progress.done) of \(progress.total) from chess.com"
        case .analysing:
            let left = progress.minutesLeft.map { $0 < 1 ? ", nearly done" : ", about \($0) min left" } ?? ""
            return "\(progress.done.formatted()) of \(progress.total.formatted()) positions\(left)"
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }

    private func report(_ stats: HistoryStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline(stats)
                section("How games end") {
                    ForEach(stats.outcomes.sorted { $0.value > $1.value }, id: \.key) { result, count in
                        statRow(label: result,
                                detail: "\(count)",
                                fraction: Double(count) / Double(max(1, stats.games)),
                                tint: result == "win" ? .green : .primary)
                    }
                }
                blunderSection("Blunders by phase", stats.byPhase,
                               order: ["opening", "middlegame", "endgame"])
                blunderSection("Blunders by piece moved", stats.byPiece, minimum: 20)
                blunderSection("Blunders by colour", stats.byColour, order: ["white", "black"])
                clockSection(stats)
                openings(stats)
            }
            .padding(.trailing, 6)
            .padding(.bottom, 8)
        }
    }

    private func headline(_ stats: HistoryStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(stats.games) games")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(stats.wins)W \(stats.draws)D \(stats.losses)L  ·  \(percent(stats.winRate)) win rate")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if stats.movesScored > 0 {
                Text("\(stats.movesScored) of your moves checked  ·  a blunder every \(stats.movesPerBlunder) moves")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("While the game was still level: \(stats.competitiveBlunders) blunders in \(stats.competitiveMoves) moves (\(percent(stats.competitiveRate)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    /// Each entry is [moves seen, blunders among them], so the bar is a rate
    /// rather than a raw count: 3 blunders in 30 moves matters more than 5 in 500.
    private func blunderSection(_ title: String, _ table: [String: [Int]],
                                order: [String]? = nil, minimum: Int = 0) -> some View {
        let keys = (order ?? table.keys.sorted {
            rate(table[$0]) > rate(table[$1])
        }).filter { (table[$0]?.first ?? 0) >= minimum && table[$0] != nil }

        let worst = keys.map { rate(table[$0]) }.max() ?? 0
        return Group {
            if !keys.isEmpty {
                section(title) {
                    ForEach(keys, id: \.self) { key in
                        let pair = table[key] ?? [0, 0]
                        statRow(label: key,
                                detail: "\(pair[1])/\(pair[0])  \(percent(rate(pair)))",
                                fraction: worst > 0 ? rate(pair) / worst : 0,
                                tint: .red)
                    }
                }
            }
        }
    }

    private func clockSection(_ stats: HistoryStats) -> some View {
        section("The clock") {
            // Numbers only. The verdict that used to sit here was written about
            // one player's games and read as a fact about everyone's.
            if let lowest = stats.clockSummary.lowestS, let average = stats.clockSummary.averageS {
                Text("Under a minute on \(stats.clockSummary.movesUnder60s) of your \(stats.movesScored) moves. "
                     + "Lowest your clock has been: \(Int(lowest))s. Average left after a move: \(Int(average))s.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospacedDigit()
            }
            if !stats.clockIsFine {
                blunderSection("", stats.byClock,
                               order: ["under 10s", "10 to 30s", "30 to 60s", "over 60s"])
            }
        }
    }

    private func openings(_ stats: HistoryStats) -> some View {
        ForEach(["white", "black"], id: \.self) { side in
            if let rows = stats.openings[side], !rows.isEmpty {
                section("Openings as \(side) (5+ games)") {
                    ForEach(rows) { row in
                        statRow(label: row.name,
                                detail: "\(row.played)g  \(percent(row.winRate))",
                                fraction: row.winRate,
                                tint: row.winRate >= 0.5 ? .green : .orange)
                    }
                }
            }
        }
    }

    private func statRow(label: String, detail: String,
                         fraction: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(0.55))
                        .frame(width: max(1, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 8)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
        }
    }

    private func rate(_ pair: [Int]?) -> Double {
        guard let pair, pair.count == 2, pair[0] > 0 else { return 0 }
        return Double(pair[1]) / Double(pair[0])
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
