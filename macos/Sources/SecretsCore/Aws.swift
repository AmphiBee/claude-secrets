import Foundation

/// Profils AWS : lus dans ~/.aws/credentials, stockés HORS environnement (export = 0), servis à la demande par
/// `credential_process` (la CLI `claude-secrets aws-credentials PROFIL`). Port de aws_profiles / aws_import.
public struct AwsProfile: Equatable, Sendable {
    public let name: String
    public let accessKeyId: String
    public let secretAccessKey: String
    public let sessionToken: String?
}

public struct AwsReport: Sendable {
    public var profiles: [String] = []
    public var activated = false
    public init() {}
}

public enum Aws {
    public static var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws") }

    public static func key(_ profile: String, _ field: String) -> String {
        var s = "", sep = false
        for u in profile.uppercased().unicodeScalars {
            if (u.value >= 65 && u.value <= 90) || (u.value >= 48 && u.value <= 57) {
                if sep && !s.isEmpty { s += "_" }; sep = false; s.unicodeScalars.append(u)
            } else { sep = true }
        }
        return "AWS_\(s)_\(field.uppercased())"
    }

    /// INI à la configparser : [section], clé = valeur ou clé : valeur, commentaires # et ;.
    static func parseINI(_ text: String) -> [(section: String, values: [String: String])] {
        var out: [(String, [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                out.append((String(line[line.index(after: line.startIndex)..<end]), [:])); continue
            }
            guard !out.isEmpty, let i = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            out[out.count - 1].1[k] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    public static func profiles(in dir: URL = Aws.dir) -> [AwsProfile] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("credentials"), encoding: .utf8) else { return [] }
        var merged: [String: [String: String]] = [:], order: [String] = []
        for (s, v) in parseINI(text) {
            if merged[s] == nil { order.append(s) }
            merged[s, default: [:]].merge(v) { _, n in n }
        }
        return order.compactMap { s in
            let d = merged[s]!
            guard let id = d["aws_access_key_id"], !id.isEmpty, let sec = d["aws_secret_access_key"], !sec.isEmpty else { return nil }
            return AwsProfile(name: s, accessKeyId: id, secretAccessKey: sec, sessionToken: d["aws_session_token"].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Copie datée avant toute modification d'un fichier de l'utilisateur.
    @discardableResult
    static func backup(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let b = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak-" + f.string(from: Date()))
        try? FileManager.default.copyItem(at: url, to: b)
        return b
    }

    /// Ajoute ou remplace `credential_process` dans la section, sans toucher au reste du fichier.
    static func setCredentialProcess(_ text: String, section: String, command: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let header = "[\(section)]"
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            return (lines + (lines.isEmpty ? [] : [""]) + [header, "credential_process = \(command)"]).joined(separator: "\n") + "\n"
        }
        var end = lines.count
        for i in (h + 1)..<lines.count where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end = i; break }
        if let i = (h + 1..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("credential_process") }) {
            lines[i] = "credential_process = \(command)"
        } else {
            lines.insert("credential_process = \(command)", at: h + 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Importe les profils dans le trousseau (hors environnement). `activate` : écrit credential_process dans
    /// ~/.aws/config et écarte ~/.aws/credentials (prioritaire), avec une copie de sauvegarde de chacun.
    public static func importProfiles(store: VaultStore, activate: Bool, dir: URL = Aws.dir, cli: String) throws -> AwsReport {
        let ps = profiles(in: dir)
        guard !ps.isEmpty else { throw BwError("Aucun profil exploitable dans \(dir.path)/credentials.") }
        try store.transaction { all in
            for p in ps {
                VaultEdit.set(&all, key(p.name, "access_key_id"), p.accessKeyId, exported: false)
                VaultEdit.set(&all, key(p.name, "secret_access_key"), p.secretAccessKey, exported: false)
                if let t = p.sessionToken { VaultEdit.set(&all, key(p.name, "session_token"), t, exported: false) }
            }
        }
        var report = AwsReport(); report.profiles = ps.map(\.name)
        guard activate else { return report }
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            throw BwError("La commande \(cli) est introuvable : credential_process ne pourrait pas fonctionner.")
        }
        let config = dir.appendingPathComponent("config"), creds = dir.appendingPathComponent("credentials")
        var text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        backup(config)
        for p in ps {
            text = setCredentialProcess(text, section: p.name == "default" ? "default" : "profile \(p.name)",
                                        command: "\(cli) aws-credentials \(p.name)")
        }
        try Data(text.utf8).write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let disabled = dir.appendingPathComponent("credentials.disabled")
        backup(creds)
        try? FileManager.default.removeItem(at: disabled)
        try FileManager.default.moveItem(at: creds, to: disabled)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: disabled.path)
        report.activated = true
        return report
    }
}
