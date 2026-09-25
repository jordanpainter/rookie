import Foundation

struct EndgameDrill: Decodable, Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }
}

struct EndgameState: Decodable {
    let drill: String
    let name: String
    let fen: String
    let status: String
    /// What the tablebase says perfect play needs from the starting position.
    let targetPlies: Int?
    let yourPlies: Int
    let optimalMoves: Int
    let turn: String
    let legal: [String: [String]]?
    let lastMove: LastMove?
    let checkSquare: String?

    // Only present on a reply to a move.
    let youPlayed: String?
    let wasOptimal: Bool?
    let bestWas: String?
    let defence: String?

    struct LastMove: Decodable { let from: String; let to: String }

    enum CodingKeys: String, CodingKey {
        case drill, name, fen, status, turn, legal, defence
        case targetPlies = "target_plies"
        case yourPlies = "your_plies"
        case optimalMoves = "optimal_moves"
        case lastMove = "last_move"
        case checkSquare = "check_square"
        case youPlayed = "you_played"
        case wasOptimal = "was_optimal"
        case bestWas = "best_was"
    }

    var isOver: Bool { status != "ongoing" }
}

@MainActor
final class EndgameStore: ObservableObject {
    @Published var drills: [EndgameDrill] = []
    @Published var selected: String = "rook"
    @Published var state: EndgameState?
    @Published var isThinking = false
    @Published var errorMessage: String?

    private var hasLoaded = false

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        request(["op": "endgame_drills"]) { data in
            struct Reply: Decodable { let drills: [EndgameDrill] }
            self.drills = (try? JSONDecoder().decode(Reply.self, from: data))?.drills ?? []
        }
        newPosition()
    }

    func newPosition() {
        request(["op": "endgame_new", "drill": selected]) { data in
            self.state = try? JSONDecoder().decode(EndgameState.self, from: data)
        }
    }

    func play(from: String, to: String) {
        guard let state, !state.isOver else { return }
        request(["op": "endgame_move", "uci": from + to]) { data in
            if let next = try? JSONDecoder().decode(EndgameState.self, from: data) {
                self.state = next
            } else if let err = try? JSONDecoder().decode([String: String].self, from: data) {
                self.errorMessage = err["error"]
            }
        }
    }

    private func request(_ payload: [String: Any], then handle: @escaping (Data) -> Void) {
        isThinking = true
        errorMessage = nil
        Task {
            defer { isThinking = false }
            do {
                let data = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { c.resume(returning: try CoachClient.send(payload)) }
                        catch { c.resume(throwing: error) }
                    }
                }
                handle(data)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
