import Foundation

struct OpeningDrillState: Decodable {
    let name: String
    let eco: String
    let fen: String
    let movesSan: [String]
    let ply: Int
    let total: Int
    let wrong: Int
    let finished: Bool
    let legal: [String: [String]]?

    // Present only on a reply to a move.
    let correct: Bool?
    let youPlayed: String?
    let expected: String?
    let reply: String?

    enum CodingKeys: String, CodingKey {
        case name, eco, fen, ply, total, wrong, finished, legal, correct, expected, reply
        case movesSan = "moves_san"
        case youPlayed = "you_played"
    }
}

@MainActor
final class OpeningDrillStore: ObservableObject {
    @Published var state: OpeningDrillState?
    @Published var lastError: String?
    /// True while drilling, so the Explore tab knows to hand the board over.
    @Published var active = false

    func start(name: String) {
        request(["op": "opening_drill", "name": name]) { data in
            if let next = try? JSONDecoder().decode(OpeningDrillState.self, from: data) {
                self.state = next
                self.active = true
                self.lastError = nil
            } else if let err = try? JSONDecoder().decode([String: String].self, from: data) {
                self.lastError = err["error"]
            }
        }
    }

    func play(from: String, to: String) {
        guard let state, !state.finished else { return }
        request(["op": "opening_drill_move", "uci": from + to]) { data in
            if let next = try? JSONDecoder().decode(OpeningDrillState.self, from: data) {
                self.state = next
            }
        }
    }

    func stop() {
        active = false
        state = nil
    }

    private func request(_ payload: [String: Any], then handle: @escaping (Data) -> Void) {
        Task {
            do {
                let data = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { c.resume(returning: try CoachClient.send(payload)) }
                        catch { c.resume(throwing: error) }
                    }
                }
                handle(data)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
