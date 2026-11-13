import Foundation

// Port de la synchronisation Bitwarden / Vaultwarden du script Python. On lance `bw`, on ne réimplémente
// pas son API. Le mot de passe maître et la session ne passent JAMAIS par un argument (visibles dans `ps`) :
// seulement par l'environnement du processus fils.

public struct BwError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}
public struct BwLocked: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "Le coffre Bitwarden est verrouillé." }
}

public let bwSessionKey = "_BW_SESSION"          // réservé : jamais affiché
public let bwDefaultFolder = "Claude Secrets"
let bwNameField = "claude_secrets_name"
let bwExportField = "claude_secrets_export"

public struct SyncReport: Sendable {
    public var added: [String] = [], updated: [String] = [], removed: [String] = []
    public var total = 0
    public var domainsChanged = false
    public init() {}
    public var changed: Bool { !(added.isEmpty && updated.isEmpty && removed.isEmpty) }
}

/// Élément Bitwarden (JSON de `bw list items`), réduit à ce dont on se sert.
public struct BwItem {
    let raw: [String: Any]
    public init(_ raw: [String: Any]) { self.raw = raw }
    var name: String { raw["name"] as? String ?? "" }
    var login: [String: Any] { raw["login"] as? [String: Any] ?? [:] }
    var fields: [[String: Any]] { raw["fields"] as? [[String: Any]] ?? [] }
    var notes: String { raw["notes"] as? String ?? "" }
}

public struct BitwardenClient: Sendable {
    public let executable: String?     // nil : recherche de `bw`
    public let store: VaultStore

    public init(store: VaultStore, executable: String? = nil) { self.store = store; self.executable = executable }

    // MARK: configuration (state.json, clé « bitwarden »)

    public static func conf() -> [String: Any] { AppState.read()["bitwarden"] as? [String: Any] ?? [:] }

    public static func setConf(_ update: [String: Any?]) {
        var c = conf()
        for (k, v) in update { c[k] = v ?? NSNull() }
        AppState.update(["bitwarden": c])
    }

    // MARK: bw

    /// Une app lancée depuis le Dock n'a pas le PATH du shell : on ajoute les emplacements usuels.
    static var searchPath: [String] {
        let home = NSHomeDirectory()
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return env + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.volta/bin", home + "/.local/bin"]
    }

    func binary() throws -> String {
        if let executable { return executable }
        for d in Self.searchPath {
            let p = d + "/bw"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        throw BwError("Le CLI Bitwarden est introuvable. Installe-le avec : brew install bitwarden-cli")
    }

    /// Exécute bw ; session et mot de passe seulement par l'environnement du processus fils.
    public func run(_ args: [String], session: String? = nil, password: String? = nil,
                    timeout: TimeInterval = 120) throws -> (rc: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try binary())
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["BW_SESSION"] = nil; env["BW_PASSWORD"] = nil
        env["PATH"] = Self.searchPath.joined(separator: ":")
        if let session { env["BW_SESSION"] = session }
        if let password { env["BW_PASSWORD"] = password }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw BwError("impossible de lancer bw") }
        // Lire les deux tubes pendant l'exécution (sinon bw se bloque sur un tube plein).
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data(), errData = Data()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit(); killer.cancel(); group.wait()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func state(session: String? = nil) throws -> [String: Any] {
        let r = try run(["status"], session: session)
        guard r.rc == 0 else { throw BwError(r.err.isEmpty ? "bw status a échoué" : r.err) }
        guard let j = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else {
            throw BwError("réponse inattendue de bw status")
        }
        return j
    }

    /// "unauthenticated", "locked" ou "unlocked".
    public func status(session: String? = nil) throws -> String {
        (try state(session: session)["status"] as? String) ?? "unauthenticated"
    }

    /// Cloud officiel si vide, sinon instance auto-hébergée (Vaultwarden inclus).
    @discardableResult
    public func setServer(_ server: String) throws -> String {
        var url = server.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        if url.isEmpty { url = "https://vault.bitwarden.com" }
        if !(url.hasPrefix("http://") || url.hasPrefix("https://")) { url = "https://" + url }
        let st = try state()
        if (st["status"] as? String ?? "unauthenticated") != "unauthenticated" {
            var current = st["serverUrl"] as? String ?? ""
            while current.hasSuffix("/") { current.removeLast() }
            if current == url { Self.setConf(["server": url]); return url }
            throw BwError("Un compte est déjà connecté sur \(current). Pour basculer vers \(url), déconnecte-toi d'abord.")
        }
        let r = try run(["config", "server", url])
        guard r.rc == 0 else { throw BwError(r.err.isEmpty ? "impossible de configurer le serveur \(url)" : r.err) }
        Self.setConf(["server": url])
        return url
    }

    static func migratorError(_ err: String) -> Bool {
        let low = err.lowercased()
        return low.contains("migrat") || low.contains("backfill") || low.contains("404")
    }

    static func firstLine(_ s: String) -> String { s.split(whereSeparator: \.isNewline).first.map(String.init) ?? "" }

    /// Connecte le compte. Retourne une session, ou nil si elle reste à ouvrir (serveur auto-hébergé plus ancien).
    public func login(email: String, password: String, code: String? = nil, method: String? = nil) throws -> String? {
        var args = ["login", email, "--raw", "--passwordenv", "BW_PASSWORD"]
        if let code, !code.isEmpty { args += ["--code", code] }
        if let method, !method.isEmpty { args += ["--method", method] }
        let r = try run(args, password: password)
        if r.rc == 0 { Self.setConf(["email": email]); return r.out }
        if let s = try? status(), s == "locked" || s == "unlocked" { Self.setConf(["email": email]); return nil }
        let low = r.err.lowercased()
        if low.contains("two-step") || low.contains("two factor") || low.contains("totp") {
            throw BwError("Ce compte demande une authentification à deux facteurs : indique le code à usage unique.")
        }
        if Self.migratorError(r.err) {
            throw BwError("Le serveur a refusé une étape que ce CLI exécute à la connexion, et le compte n'a pas été connecté. "
                          + "Ton serveur est probablement plus ancien que le CLI : aligne les versions.")
        }
        throw BwError(Self.firstLine(r.err).isEmpty ? "échec de la connexion" : Self.firstLine(r.err))
    }

    /// Déverrouille et retourne la clé de session (récupérée même si la migration de clés échoue après coup).
    public func unlock(password: String) throws -> String {
        let r = try run(["unlock", "--raw", "--passwordenv", "BW_PASSWORD"], password: password)
        if r.rc == 0 { return r.out }
        if let candidate = r.out.split(whereSeparator: \.isNewline).last.map({ $0.trimmingCharacters(in: .whitespaces) }),
           !candidate.isEmpty, (try? status(session: candidate)) == "unlocked" { return candidate }
        if Self.migratorError(r.err) {
            throw BwError("Le serveur a refusé une étape de migration que ce CLI exécute après le déverrouillage : aligne le CLI sur la version du serveur.")
        }
        throw BwError(Self.firstLine(r.err).isEmpty ? "mot de passe maître refusé" : Self.firstLine(r.err))
    }

    func storedSession() -> String? {
        (try? store.load(includeReserved: true))?.first { $0.name == bwSessionKey }?.value
    }

    public func saveSession(_ session: String) throws {
        try store.transaction { VaultEdit.set(&$0, bwSessionKey, session, exported: false) }
    }

    public func forgetSession() throws {
        try store.transaction { $0.removeAll { $0.name == bwSessionKey } }
    }

    /// Session valide, ou BwLocked si un mot de passe manque.
    public func session(password: String? = nil) throws -> String {
        if let s = storedSession(), (try? status(session: s)) == "unlocked" { return s }
        if try status() == "unauthenticated" { throw BwError("Aucun compte Bitwarden connecté : configure d'abord la synchronisation.") }
        guard let password else { throw BwLocked() }
        let s = try unlock(password: password)
        try saveSession(s)
        return s
    }

    public func logout() throws {
        try forgetSession()
        let r = try run(["logout"])
        Self.setConf(["email": nil])
        if r.rc != 0 { throw BwError(r.err.isEmpty ? r.out : r.err) }
    }

    // MARK: éléments → secrets

    func folderId(session: String, name: String) throws -> String {
        let r = try run(["list", "folders"], session: session)
        guard r.rc == 0 else { throw BwError(r.err.isEmpty ? "impossible de lister les dossiers" : r.err) }
        let folders = (try? JSONSerialization.jsonObject(with: Data((r.out.isEmpty ? "[]" : r.out).utf8))) as? [[String: Any]] ?? []
        let want = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let f = folders.first(where: { (($0["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased() == want }),
           let id = f["id"] as? String { return id }
        throw BwError("Le dossier « \(name) » n'existe pas dans ton coffre. Crée-le dans Bitwarden et places-y les éléments à partager avec Claude Secrets.")
    }

    func items(session: String, folder: String) throws -> [BwItem] {
        let id = try folderId(session: session, name: folder)
        let r = try run(["list", "items", "--folderid", id], session: session)
        guard r.rc == 0 else { throw BwError(r.err.isEmpty ? "impossible de lister les éléments" : r.err) }
        let arr = (try? JSONSerialization.jsonObject(with: Data((r.out.isEmpty ? "[]" : r.out).utf8))) as? [[String: Any]] ?? []
        return arr.map(BwItem.init)
    }

    public static func slug(_ text: String?) -> String {
        var s = ""
        var pendingSep = false
        for u in (text ?? "").unicodeScalars {
            if (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) {
                if pendingSep && !s.isEmpty { s += "_" }
                pendingSep = false
                s += String(u).uppercased()
            } else { pendingSep = true }
        }
        if let f = s.unicodeScalars.first, f.value >= 48 && f.value <= 57 { s = "X" + s }
        return s
    }

    /// Port de bw_map : nom → variable ; identifiant + mot de passe → paire ; champs masqués → NOM_CHAMP.
    public static func map(_ items: [BwItem]) -> [(name: String, value: String, exported: Bool)] {
        var out: [(String, String, Bool)] = []
        for it in items {
            var fields: [(name: String, f: [String: Any])] = []
            for f in it.fields { if let n = (f["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { fields.append((n, f)) } }
            func field(_ n: String) -> [String: Any]? { fields.last { $0.name == n }?.f }
            let forced = field(bwNameField)?["value"] as? String
            let base = slug(forced.flatMap { $0.isEmpty ? nil : $0 } ?? it.name)
            if base.isEmpty { continue }
            var exported = true
            if let m = (field(bwExportField)?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ["false", "0", "non", "no"].contains(m) { exported = false }
            let user = ((it.login["username"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pwd = (it.login["password"] as? String) ?? ""
            if !pwd.isEmpty && !user.isEmpty { out.append(("\(base)_USER", user, exported)); out.append(("\(base)_PASSWORD", pwd, exported)) }
            else if !pwd.isEmpty { out.append((base, pwd, exported)) }
            var done = Set<String>()
            for (fname, _) in fields where done.insert(fname).inserted {
                if fname == bwNameField || fname == bwExportField { continue }
                let f = field(fname)!
                guard (f["type"] as? Int) == 1, let v = f["value"] as? String, !v.isEmpty else { continue }
                out.append(("\(base)_\(slug(fname))", v, exported))
            }
            let note = it.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty && pwd.isEmpty && fields.isEmpty { out.append((base, note, exported)) }
        }
        return out
    }

    /// Nom d'hôte du premier site web de l'élément (adresses locales et applications mobiles ignorées).
    public static func host(_ item: BwItem) -> String? {
        for u in item.login["uris"] as? [[String: Any]] ?? [] {
            let uri = ((u["uri"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if uri.isEmpty || uri.hasPrefix("androidapp://") || uri.hasPrefix("iosapp://") { continue }
            guard var h = URLComponents(string: uri.contains("://") ? uri : "//" + uri)?.host?.lowercased() else { continue }
            if h.hasPrefix("www.") { h.removeFirst(4) }
            let digitsOnly = !h.replacingOccurrences(of: ".", with: "").isEmpty && h.replacingOccurrences(of: ".", with: "").allSatisfy(\.isNumber)
            if h.filter({ $0 == "." }).count >= 1 && !digitsOnly
                && !(h.hasSuffix(".local") || h.hasSuffix(".localhost") || h.hasSuffix(".test")) { return h }
        }
        return nil
    }

    public static func domains(_ items: [BwItem]) -> [String: String] {
        var out: [String: String] = [:]
        for it in items {
            guard let h = host(it) else { continue }
            for (name, _, _) in map([it]) {
                out[name] = h
                for suffix in ["_USER", "_PASSWORD"] where name.hasSuffix(suffix) { out[String(name.dropLast(suffix.count))] = h }
            }
        }
        return out
    }

    // MARK: synchronisation

    /// Synchronise le dossier Bitwarden vers le trousseau. `prune` ne retire que ce qui vient de ce dossier.
    public func sync(password: String? = nil, prune: Bool = false, folder: String? = nil) throws -> SyncReport {
        let folder = folder ?? (Self.conf()["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bwDefaultFolder
        let session = try session(password: password)
        _ = try run(["sync"], session: session)
        let items = try self.items(session: session, folder: folder)
        let mapped = Self.map(items)
        if prune && mapped.isEmpty {
            throw BwError("Le dossier « \(folder) » est vide : suppression annulée. Un dossier vide ou mal nommé effacerait tout ce qui en vient.")
        }
        let origin = "bitwarden:\(folder)"
        let box = ReportBox()
        // Tout se calcule DANS la transaction, sur les données verrouillées et relues : une modification
        // faite entre-temps (dans l'app ou la CLI) n'est jamais écrasée par une photo plus ancienne.
        let final = try store.transaction { all in
            var known: [String: VaultSecret] = [:]
            for s in all { known[s.name] = s }
            var r = SyncReport()
            for (name, value, export) in mapped {
                if let cur = known[name] {
                    if cur.value != value || cur.exported != export || cur.source != origin { r.updated.append(name) } else { continue }
                } else { r.added.append(name) }
                VaultEdit.set(&all, name, value, exported: export, source: origin)
                known[name] = VaultSecret(name: name, value: value, exported: export, source: origin)
            }
            if prune {
                let wanted = Set(mapped.map(\.name))
                for (name, s) in known where s.source == origin && !name.hasPrefix("_") && !wanted.contains(name) {
                    all.removeAll { $0.name == name }
                    r.removed.append(name)
                }
            }
            r.added.sort(by: codePointLess); r.updated.sort(by: codePointLess); r.removed.sort(by: codePointLess)
            box.report = r
        }
        var report = box.report
        report.total = Set(mapped.map(\.name)).count
        // Adresses web (classement par service) : pas des secrets, donc state.json ; seuls les noms vivants restent.
        let names = Set(final.map(\.name))
        let valid = names.union(names.flatMap { n in ["_USER", "_PASSWORD"].compactMap { n.hasSuffix($0) ? String(n.dropLast($0.count)) : nil } })
        let old = AppState.read()["domains"] as? [String: String] ?? [:]
        let new = old.merging(Self.domains(items)) { _, n in n }.filter { valid.contains($0.key) }
        if new != old { AppState.update(["domains": new]); report.domainsChanged = true }
        return report
    }
}

final class ReportBox: @unchecked Sendable { var report = SyncReport() }
