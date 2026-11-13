import Foundation
import SecretsCore

/// Synchronisation Bitwarden et profils AWS. Tout ce qui parle à `bw` ou au disque tourne hors du fil principal.
extension VaultModel {
    static let autoSyncEvery: TimeInterval = 10 * 60      // intervalle minimal entre deux synchros automatiques

    var bwEmail: String? { BitwardenClient.conf()["email"] as? String }
    var bwConfigured: Bool { !(bwEmail ?? "").isEmpty }
    var bwFolder: String { (BitwardenClient.conf()["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bwDefaultFolder }
    var autoSyncEnabled: Bool { (BitwardenClient.conf()["auto_sync"] as? Bool) ?? true }

    func setAutoSync(_ on: Bool) {
        BitwardenClient.setConf(["auto_sync": on])
        objectWillChange.send()
        if on { autoSync(force: true) }
    }

    /// ⌘R : synchronise, ou propose la configuration si aucun compte n'est connecté.
    func syncNow() {
        guard bwConfigured else { sheet = .bwSetup; return }
        runSync(password: nil, auto: false)
    }

    /// Synchro silencieuse (lancement, réouverture) : ne demande jamais le mot de passe maître, ne supprime rien.
    func autoSync(force: Bool = false) {
        guard isReady, !syncing, bwConfigured, autoSyncEnabled else { return }
        if !force, let last = lastSync, Date().timeIntervalSince(last) < Self.autoSyncEvery { return }
        runSync(password: nil, auto: true)
    }

    func runSync(password: String?, auto: Bool) {
        if syncing { if !auto { flash("Une synchronisation est déjà en cours") }; return }
        syncing = true; lastSync = Date()
        if !auto { flash("Synchronisation Bitwarden…") }
        let client = BitwardenClient(store: store)
        Task {
            defer { syncing = false }
            do {
                let report = try await Task.detached(priority: .utility) { try client.sync(password: password) }.value
                if report.changed {
                    // Relecture après notre propre écriture (nous sommes le dernier écrivain : rapide).
                    let store = self.store
                    apply(try await Task.detached { try store.load() }.value)
                } else if report.domainsChanged {
                    apply(try await Task.detached { [store] in try store.load() }.value)   // le classement peut changer seul
                }
                if auto && !report.changed { return }          // rien à signaler
                if !report.changed { flash("Bitwarden à jour · \(report.total) secret\(report.total > 1 ? "s" : "")"); return }
                var parts: [String] = []
                for (label, names) in [("ajouté", report.added), ("mis à jour", report.updated), ("supprimé", report.removed)] where !names.isEmpty {
                    parts.append("\(names.count) \(label)\(names.count > 1 ? "s" : "")")
                }
                flash("Bitwarden · " + parts.joined(separator: ", "))
            } catch is BwLocked {
                if auto { flash("Bitwarden verrouillé : synchronisation en attente", seconds: 8, action: ("Déverrouiller", "bw-unlock")) }
                else { sheet = .bwUnlock }
            } catch {
                let msg = "Bitwarden : \(error)".split(separator: "\n").first.map(String.init) ?? "Bitwarden : échec"
                if auto { if autoErrorShown { return }; autoErrorShown = true }
                flash(msg, seconds: 6)
            }
        }
    }

    /// Première connexion (ou nouvelle clé de session). Le mot de passe maître n'est jamais conservé :
    /// seule la clé de session va dans le trousseau.
    func setupBitwarden(server: String, email: String, password: String, code: String, folder: String,
                        done: @escaping (String?) -> Void) {
        let client = BitwardenClient(store: store)
        let folder = folder.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let st = try client.state()
                    var session: String
                    if (st["status"] as? String ?? "unauthenticated") == "unauthenticated" {
                        try client.setServer(server)
                        let s = try client.login(email: email.trimmingCharacters(in: .whitespaces), password: password,
                                                 code: code.trimmingCharacters(in: .whitespaces))
                        session = try s ?? client.unlock(password: password)
                    } else {
                        var url = (st["serverUrl"] as? String) ?? ""; while url.hasSuffix("/") { url.removeLast() }
                        BitwardenClient.setConf(["server": url, "email": (st["userEmail"] as? String) ?? email])
                        session = try client.unlock(password: password)
                    }
                    try client.saveSession(session)
                    BitwardenClient.setConf(["folder": folder.isEmpty ? bwDefaultFolder : folder])
                }.value
                done(nil)
                sheet = nil
                objectWillChange.send()
                runSync(password: nil, auto: false)
            } catch { done("\(error)".split(separator: "\n").first.map(String.init) ?? "échec") }
        }
    }

    func unlockBitwarden(password: String, done: @escaping (String?) -> Void) {
        sheet = nil
        runSync(password: password, auto: false)
        done(nil)
    }

    func bwLogout() {
        let client = BitwardenClient(store: store)
        Task {
            do { try await Task.detached { try client.logout() }.value; flash("Compte Bitwarden déconnecté") }
            catch { flash("Déconnexion : \(error)".split(separator: "\n").first.map(String.init) ?? "échec") }
            objectWillChange.send()
        }
    }

    // MARK: AWS

    func importAws(activate: Bool) {
        let store = self.store
        let cli = NSHomeDirectory() + "/.local/bin/claude-secrets"
        Task {
            do {
                let r = try await Task.detached { try Aws.importProfiles(store: store, activate: activate, cli: cli) }.value
                apply(try await Task.detached { try store.load() }.value)
                flash("\(r.profiles.count) profil\(r.profiles.count > 1 ? "s" : "") AWS importé\(r.profiles.count > 1 ? "s" : "")"
                      + (r.activated ? " · credential_process activé" : " · hors environnement"), seconds: 5)
            } catch { flash("AWS : \(error)".split(separator: "\n").first.map(String.init) ?? "échec", seconds: 6) }
        }
    }
}
