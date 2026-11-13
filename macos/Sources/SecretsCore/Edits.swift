import Foundation

/// Opérations d'édition pures sur la liste des secrets (appelées dans une transaction).
public enum VaultEdit {
    public static let reservedSuffixes = ["_USER", "_PASSWORD"]

    /// Nom saisi → nom de variable : majuscules, `-` et espaces → `_`.
    public static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    /// Noms de trousseau qui composent une entrée.
    public static func names(_ kind: EntryKind, _ base: String) -> [String] {
        switch kind {
        case .pair: return [base + "_USER", base + "_PASSWORD"]
        case .aws: return [base + awsIdSuffix, base + awsSecretSuffix, base + "_SESSION_TOKEN"]
        case .single: return [base]
        }
    }

    /// Enregistre (remplace) un secret.
    public static func set(_ all: inout [VaultSecret], _ name: String, _ value: String,
                           exported: Bool = true, source: String = "local") {
        all.removeAll { $0.name == name }
        all.append(VaultSecret(name: name, value: value, exported: exported, source: source))
    }

    public static func setLogin(_ all: inout [VaultSecret], base: String, user: String, password: String) {
        set(&all, base + "_USER", user)
        set(&all, base + "_PASSWORD", password)
    }

    /// Supprime une entrée et rend les instantanés fidèles (valeur, export, origine) pour l'annulation.
    @discardableResult
    public static func delete(_ all: inout [VaultSecret], _ kind: EntryKind, _ base: String) -> [VaultSecret] {
        let ns = Set(names(kind, base))
        let snaps = all.filter { ns.contains($0.name) }
        all.removeAll { ns.contains($0.name) }
        return snaps
    }

    /// Restaure une suppression annulée, `source` et `export` conservés.
    public static func restore(_ all: inout [VaultSecret], _ snaps: [VaultSecret]) {
        for s in snaps { set(&all, s.name, s.value, exported: s.exported, source: s.source) }
    }

    /// Lignes `NOM=valeur` ou `export NOM=valeur` d'un .env (port de parse_env).
    public static func parseEnv(_ text: String) -> [(name: String, value: String)] {
        let re = try! NSRegularExpression(pattern: #"^(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)$"#)
        var out: [(String, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let r = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: r),
                  let n = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line) else { continue }
            var val = String(line[v]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, let f = val.first, f == val.last, f == "\"" || f == "'" { val = String(val.dropFirst().dropLast()) }
            if !val.isEmpty { out.append((String(line[n]), val)) }
        }
        return out
    }
}
