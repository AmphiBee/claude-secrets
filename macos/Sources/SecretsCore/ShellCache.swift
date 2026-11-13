import Foundation

/// Cache lu par les shells : lignes `export NOM='valeur'`, uniquement les secrets exportés.
/// Créé en 0600 dès l'ouverture (jamais lisible par d'autres, même un instant).
public enum ShellCache {
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        // Une app lancée depuis le Dock n'a pas XDG_RUNTIME_DIR (défini dans ~/.zshenv) : on prend TMPDIR.
        var dir = env["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        return URL(fileURLWithPath: dir).appendingPathComponent("claude-secrets.env")
    }
    public static var defaultLockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-secrets/.vault.lock")
    }

    /// shlex.quote de Python.
    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) && $0.isASCII }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func render(_ secrets: [VaultSecret]) -> String {
        let lines = secrets.filter { $0.exported && !$0.name.hasPrefix("_") }.map { "export \($0.name)=\(quote($0.value))" }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func write(_ secrets: [VaultSecret], to url: URL) throws {
        let tmp = url.deletingPathExtension().appendingPathExtension("tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw VaultError.lock(errno) }
        let data = Data(render(secrets).utf8)
        let ok = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == data.count }
        close(fd)
        guard ok else { try? FileManager.default.removeItem(at: tmp); throw VaultError.lock(EIO) }
        guard rename(tmp.path, url.path) == 0 else { throw VaultError.lock(errno) }
    }
}
