import Foundation

/// ~/.config/claude-secrets/state.json : préférences et données non secrètes, partagées avec la CLI.
/// On ne réécrit jamais le fichier en entier : seules nos clés changent (la config Bitwarden y vit aussi).
public enum AppState {
    /// Surchargeable (tests : jamais le vrai fichier).
    /// CLAUDE_SECRETS_STATE : fichier d'état de test (démo, essais) pour ne jamais toucher à celui de l'utilisateur.
    nonisolated(unsafe) public static var url: URL = {
        if let p = ProcessInfo.processInfo.environment["CLAUDE_SECRETS_STATE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-secrets/state.json")
    }()

    public static func read() -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    public static func update(_ fields: [String: Any]) {
        var s = read()
        for (k, v) in fields { s[k] = v }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? d.write(to: url, options: .atomic)
        }
    }
}
