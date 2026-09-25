import Foundation

struct OpeningHit: Decodable, Identifiable, Equatable {
    let eco: String
    let name: String
    var id: String { eco + name }
}

private struct SearchReply: Decodable { let results: [OpeningHit] }

/// The Explore tab's opening picker.
///
/// Explore could show any of 3,810 openings and offered no way to pick one:
/// the only route in was asking Chichi by name, which requires knowing the name
/// already. Searching is a database query, so it happens here rather than
/// through him.
@MainActor
final class OpeningSearch: ObservableObject {
    @Published var query: String = "" { didSet { schedule() } }
    @Published var results: [OpeningHit] = []
    @Published var isOpen = false

    private var pending: Task<Void, Never>?

    func open() {
        isOpen = true
        schedule()
    }

    func close() {
        isOpen = false
        query = ""
        results = []
    }

    /// Debounced: a query per keystroke would hammer the daemon for answers
    /// nobody reads, since the next keystroke is 100ms away.
    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    private func run() async {
        let payload: [String: Any] = ["op": "opening_search", "query": query, "limit": 40]
        guard let data = try? await CoachClient.sendAsync(payload),
              let reply = try? JSONDecoder().decode(SearchReply.self, from: data)
        else { return }
        results = reply.results
    }

    func choose(_ hit: OpeningHit) {
        let name = hit.name
        Task {
            _ = try? await CoachClient.sendAsync(["op": "opening_show", "name": name])
            close()
        }
    }
}
