import Foundation

/// One turn from the model: what it said, and a session id when there is one.
struct AgentTurnResult {
    let text: String
    let sessionId: String?
}

/// The one way to the model.
///
/// The app never asks the model to do anything but read a packet and write a
/// line: every fact is worked out before it is sent, and checked after. That is
/// why it can talk to a model on your own machine with nothing in between.
enum CoachModel {
    static func ask(_ message: String, timeoutSeconds: Int = 180) async throws -> AgentTurnResult {
        let text = try await OllamaClient.shared.ask(message, timeoutSeconds: timeoutSeconds)
        return AgentTurnResult(text: text, sessionId: nil)
    }

    /// Loads the model before the first real question, so that question does
    /// not pay the cold start.
    static func warmUp() async {
        await OllamaClient.shared.load()
    }
}

enum OllamaError: LocalizedError {
    case notRunning
    case modelMissing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama isn't running. Open it, then ask again."
        case .modelMissing(let model):
            // Ends on words, not the command: the chat appends its own sentence,
            // and a bare command ran straight into it.
            return "The model \(model) isn't installed. To get it, run ollama pull \(model) in Terminal."
        case .failed(let why):
            return "Ollama couldn't answer: \(why)"
        }
    }
}

/// Talks to a local Ollama server, and keeps the conversation itself.
///
/// The app keeps the transcript itself, because without it "why?" arrives with
/// nothing before it and means nothing. Kept short on purpose: a coaching packet is several hundred tokens, and a model that can
/// see a long run of its own lines starts repeating them.
actor OllamaClient {
    static let shared = OllamaClient()

    private let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
    /// Ollama's own default is small, and when a prompt overflows it drops the
    /// oldest tokens first, which is the persona. Persona, packet and a few
    /// turns come to about 8k. Changing this between requests forces a reload,
    /// so it is one constant, warm-up included.
    private static let contextTokens = 16_384
    private static let historyLimit = 6

    private var history: [[String: String]] = []
    private lazy var persona = Self.loadPersona()

    func ask(_ message: String, timeoutSeconds: Int) async throws -> String {
        let user = ["role": "user", "content": message]
        let messages = [["role": "system", "content": persona]] + history + [user]
        let reply = try await post(messages, timeoutSeconds: timeoutSeconds)
        history = Array((history + [user, ["role": "assistant", "content": reply]])
            .suffix(Self.historyLimit))
        return reply
    }

    /// An empty message list makes Ollama load the model and do nothing else.
    func load() async {
        _ = try? await post([], timeoutSeconds: 120)
    }

    private func post(_ messages: [[String: String]], timeoutSeconds: Int) async throws -> String {
        let model = AppConfig.shared.model
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "stream": false,
            // Reasoning costs 20 seconds a turn to produce one sentence. Models
            // that cannot reason accept the flag and ignore it.
            "think": false,
            "options": ["num_ctx": Self.contextTokens],
        ] as [String: Any])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where
                    [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(error.code) {
            throw OllamaError.notRunning
        }

        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw OllamaError.modelMissing(model) }
        guard status == 200 else {
            throw OllamaError.failed((body["error"] as? String) ?? "HTTP \(status)")
        }
        let message = body["message"] as? [String: Any]
        return ((message?["content"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bundled persona, plus the player's rating when an account is linked,
    /// so the coaching is pitched at the level they actually play.
    private static func loadPersona() -> String {
        let url = Bundle.module.url(forResource: "persona", withExtension: "md",
                                    subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "persona", withExtension: "md")
        var text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if let rating = AppConfig.shared.rating {
            text += "\n\nThe player is rated about \(rating) on chess.com."
        }
        return text
    }
}
