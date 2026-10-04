import Foundation

/// The computed position facts, minus the parts only the app needs, and minus
/// whatever was already said last turn.
///
/// `describe` returns the board three times over: `pieces` as prose for Chichi
/// to read, and `squares` plus `squares_recent` as maps for the app to check
/// his answer against. He needs the first and none of the rest, and the two
/// maps are about a third of the packet. A model reading the same board in
/// three formats is being given work, not information.
enum Facts {
    /// `summary` is a finished English sentence, and a finished sentence in the
    /// packet is a sentence that comes back out verbatim. It stays in the reply
    /// for the app, which shows it while the model is still thinking, and never
    /// reaches the model.
    private static let appOnly = ["squares", "squares_recent", "attack_map", "summary",
                                  "legal_san", "owners", "owners_recent"]

    /// Where each kind of ranked entry also appears in raw form. Dropping an
    /// entry from `worth_saying` alone achieved nothing: the same piece was
    /// still sitting in `your_hanging`, and that is where it was read from.
    private static let rawList = ["your_hanging": "your_hanging",
                                  "their_hanging": "their_hanging",
                                  "your_fork": "your_forks"]

    /// What a ranked entry is *about*: the kind of thing plus the piece it
    /// concerns. Two turns with the same key are two turns saying the same
    /// thing, whatever words come out.
    private static func key(_ entry: [String: Any]) -> String? {
        guard let kind = entry["kind"] as? String else { return nil }
        let subject = (entry["square"] as? String) ?? (entry["move"] as? String) ?? ""
        return "\(kind):\(subject)"
    }

    /// - Parameter alreadySaid: the headline key from the previous turn, which
    ///   is dropped from the ranked list rather than merely discouraged.
    ///
    /// Telling the model not to repeat itself does not work, and neither does
    /// withholding the wording: handed the same top fact twice it writes the
    /// same sentence twice, because that is the obvious sentence for those
    /// fields. It cannot say what it has not been given, so the fact it
    /// already used is removed and the next one down leads instead.
    /// Take the suppressed fact out of the raw list it also lives in, so the
    /// packet genuinely does not contain it any more.
    private static func forget(_ said: String, in object: inout [String: Any]) {
        let parts = said.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let listName = rawList[parts[0]],
              var list = object[listName] as? [[String: Any]] else { return }
        let subject = parts[1]
        list.removeAll { entry in
            (entry["square"] as? String) == subject
                || "\(entry["from"] as? String ?? "")-\(entry["to"] as? String ?? "")" == subject
        }
        object[listName] = list
    }

    /// What gives a puzzle away: the mate, the checks, the forks, and the ranked
    /// list whose top entry is usually the answer. A drill exists to be worked
    /// out, and one question ("i dont see it, whats the idea?") was answered
    /// with "Qh7+ wins the game in two moves", which ends it.
    private static let solution = ["mate_in", "your_checks", "your_forks", "worth_saying"]

    /// - Parameter hidingSolution: true while a puzzle is on screen.
    static func forModel(_ json: String,
                         alreadySaid: String? = nil,
                         hidingSolution: Bool = false) -> (packet: String, headline: String?) {
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (json, nil) }
        // In check, the only useful sentence is how to get out, and the legal
        // moves are stripped with everything else the model does not need. So
        // the coaching line was "You are in check", which the board, the status
        // line and the player all knew already, and the next one was deleted as
        // a duplicate. In check there are rarely more than a handful of moves.
        if object["in_check"] as? Bool == true, let legal = object["legal_san"] {
            object["ways_out"] = legal
        }
        for name in appOnly { object.removeValue(forKey: name) }
        if hidingSolution { for name in solution { object.removeValue(forKey: name) } }

        var headline: String?
        if var ranked = object["worth_saying"] as? [[String: Any]] {
            if let alreadySaid {
                ranked.removeAll { key($0) == alreadySaid }
                forget(alreadySaid, in: &object)
            }
            object["worth_saying"] = ranked
            headline = ranked.first.flatMap(key)
        }

        guard let trimmed = try? JSONSerialization.data(withJSONObject: object,
                                                        options: [.sortedKeys]),
              let text = String(data: trimmed, encoding: .utf8)
        else { return (json, headline) }
        return (text, headline)
    }
}
