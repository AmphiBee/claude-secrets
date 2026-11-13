import Foundation

/// ~/.config/claude-secrets/state.json : préférences et données non secrètes, partagées avec la CLI.
/// On ne réécrit jamais le fichier en entier : seules nos clés changent (la config Bitwarden y vit aussi).
enum AppState {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-secrets/state.json")
    }

    static func read() -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    static func update(_ fields: [String: Any]) {
        var s = read()
        for (k, v) in fields { s[k] = v }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? d.write(to: url, options: .atomic)
        }
    }
}
