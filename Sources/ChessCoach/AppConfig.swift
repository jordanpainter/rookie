import Foundation

/// How the coach is reached, read once at launch from the same `config.json`
/// the Python side keeps its settings in, so there is one file of settings
/// rather than two.
///
/// The default is Ollama, running the model on this machine.
struct AppConfig {
    /// The Ollama model tag. Chichi's voice was tuned against gemma4:12b, and a
    /// different model will give a different coach.
    let model: String
    /// The linked chess.com rating, so the coach can pitch at the right level.
    /// Rapid first, which is the one most people's rating actually reflects.
    let rating: Int?

    /// Re-read when the model is changed in Settings, so the next thing the
    /// coach says goes to the new one without a restart.
    static private(set) var shared = load()

    static func reload() { shared = load() }

    /// Writes one setting into the data folder's `config.json`, keeping
    /// everything else in it: the same file holds the chess.com account, the
    /// ratings derived from it, and the backend.
    static func setModel(_ tag: String) {
        let path = Paths.runtimeDir + "/config.json"
        var object = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        object["model"] = tag
        if let data = try? JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        reload()
    }

    private static func load() -> AppConfig {
        let url = URL(fileURLWithPath: Paths.runtimeDir + "/config.json")
        let object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func value(_ key: String, _ fallback: String) -> String {
            let set = (object[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return set.isEmpty ? fallback : set
        }
        let ratings = object["ratings"] as? [String: Int] ?? [:]
        return AppConfig(model: value("model", "gemma4:12b"),
                         rating: ratings["rapid"] ?? ratings["blitz"] ?? ratings["bullet"])
    }
}
