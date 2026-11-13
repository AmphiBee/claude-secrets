import Foundation
import SecretsCore

enum GroupMode: String { case service, type }

struct Toast: Equatable {
    var text: String
    var actionLabel: String?
    var actionKey: String?     // clé de corbeille pour « Annuler »
}

enum ActiveSheet: Identifiable, Equatable {
    case newSecret, edit(Entry), importEnv, group(Entry), bwSetup, bwUnlock, awsImport
    var id: String {
        switch self {
        case .newSecret: return "new"
        case .edit(let e): return "edit:" + e.base
        case .importEnv: return "import"
        case .group(let e): return "group:" + e.base
        case .bwSetup: return "bwsetup"
        case .bwUnlock: return "bwunlock"
        case .awsImport: return "awsimport"
        }
    }
}

/// Section affichée : un groupe (service) ou une catégorie (mode « par type »).
struct Section: Identifiable {
    let id: String
    let label: String
    let tag: String?          // PROJET / MANUEL
    let members: [Entry]
}

final class SnapshotBox: @unchecked Sendable { var snaps: [VaultSecret] = [] }

@MainActor
final class VaultModel: ObservableObject {
    enum Phase { case loading, ready, failed(String) }

    @Published var phase: Phase = .loading
    @Published var query = ""
    @Published var expanded = Set<String>()
    @Published var revealed = Set<String>()
    @Published var mode: GroupMode = .service { didSet { if mode != oldValue { AppState.update(["group_by": mode.rawValue]) } } }
    @Published var toast: Toast?
    @Published var sheet: ActiveSheet?
    @Published var confirmAWS: Entry?
    @Published var syncing = false
    var lastSync: Date?
    var autoErrorShown = false

    @Published private(set) var sections: [Section] = []
    private var entries: [Entry] = []
    private var taxonomy = Taxonomy([])
    private var domains: [String: String] = [:]
    private var groupOverrides: [String: String] = [:]
    private var trash: [String: [VaultSecret]] = [:]
    private var trashCounter = 0
    private var loadedAt: Date?
    let store: VaultStore

    init(store: VaultStore = KeychainVaultStore()) {
        self.store = store
        let m = AppState.read()["group_by"] as? String
        mode = GroupMode(rawValue: m ?? "") ?? .service
    }

    // MARK: chargement (une seule lecture du trousseau, puis tout en mémoire)

    func load(force: Bool = false) {
        if !force, case .ready = phase { return }
        phase = .loading
        let store = self.store
        Task {
            do {
                let secrets = try await Task.detached(priority: .userInitiated) { try store.load() }.value
                apply(secrets)
            } catch {
                phase = .failed("\(error)")
            }
        }
    }

    func apply(_ secrets: [VaultSecret]) {
        entries = grouped(secrets.map { ($0.name, $0.value, $0.exported) })
        let st = AppState.read()
        domains = st["domains"] as? [String: String] ?? [:]
        groupOverrides = st["groups"] as? [String: String] ?? [:]
        taxonomy = Taxonomy(entries, domains: domains, overrides: groupOverrides)
        loadedAt = Date()
        phase = .ready
        rebuild()
        if lastSync == nil { Task { try? await Task.sleep(for: .seconds(1.5)); autoSync() } }
    }

    /// Ferme tout et libère les valeurs : appelé quand la fenêtre est masquée.
    func hide() {
        query = ""; expanded = []; revealed = []; toast = nil; sheet = nil; confirmAWS = nil
    }

    /// Masquage prolongé : on relâche aussi les valeurs de la mémoire.
    func releaseValues() {
        hide(); trash = [:]; entries = []; lastSync = nil; sections = []; taxonomy = Taxonomy([]); phase = .loading; loadedAt = nil
    }

    // MARK: affichage

    func rebuild() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? entries : entries.filter { e in
            matches(e, q) || taxonomy.labelOf(e.base).lowercased().contains(q)
        }
        switch mode {
        case .service:
            sections = taxonomy.group(filtered).map {
                Section(id: $0.id, label: $0.label, tag: tag(for: $0), members: $0.members)
            }
        case .type:
            let order: [(String, (Entry) -> Bool)] = [
                ("Clés et tokens", { $0.kind == .single && $0.exported }),
                ("Identifiants", { $0.kind == .pair }),
                ("AWS", { $0.kind == .aws }),
                ("Hors environnement", { $0.kind == .single && !$0.exported }),
            ]
            sections = order.compactMap { label, f in
                let m = filtered.filter(f)
                return m.isEmpty ? nil : Section(id: "type:\(label)", label: label, tag: nil, members: m)
            }
        }
    }

    private func matches(_ e: Entry, _ q: String) -> Bool {
        e.base.lowercased().contains(q) || (e.user?.lowercased().contains(q) ?? false)
    }

    private func tag(for g: Group) -> String? {
        g.manual ? "MANUEL" : (g.kind == .project ? "PROJET" : nil)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var resultCount: Int { sections.reduce(0) { $0 + $1.members.count } }

    /// Peu de résultats : les groupes s'ouvrent seuls.
    func isExpanded(_ s: Section) -> Bool {
        expanded.contains(s.id) || (isSearching && resultCount <= 12)
    }

    func toggle(_ s: Section) {
        if expanded.contains(s.id) { expanded.remove(s.id) } else { expanded.insert(s.id) }
    }

    func label(of e: Entry) -> String { taxonomy.labelOf(e.base) }

    // MARK: actions

    func copy(_ e: Entry) {
        Clipboard.copy(e.value)
        flash(e.kind == .pair ? "Mot de passe copié · presse-papier vidé dans 45 s" : "Copié · presse-papier vidé dans 45 s")
    }

    func copyUser(_ e: Entry) {
        guard let u = e.user else { return }
        Clipboard.copy(u)
        flash("Identifiant copié · presse-papier vidé dans 45 s")
    }

    /// ⏎ dans la recherche : copie le premier résultat.
    func copyFirst() {
        if let e = sections.first?.members.first { copy(e) }
    }

    func toggleReveal(_ e: Entry) {
        if revealed.contains(e.base) { revealed.remove(e.base) } else { revealed.insert(e.base) }
    }

    func flash(_ text: String, seconds: Double = 3, action: (String, String)? = nil) {
        let t = Toast(text: text, actionLabel: action?.0, actionKey: action?.1)
        toast = t
        Task { try? await Task.sleep(for: .seconds(seconds)); if toast == t { toast = nil } }
    }

    // MARK: écriture (toujours dans une transaction : verrou, relecture, écriture, cache du shell)

    /// Exécute une modification hors du fil principal, puis met la liste à jour sans relire le trousseau.
    private func write(_ body: @escaping @Sendable (inout [VaultSecret]) -> Void,
                       done: @escaping (Bool) -> Void = { _ in }) {
        let store = self.store
        Task {
            do {
                let secrets = try await Task.detached(priority: .userInitiated) { try store.transaction(body) }.value
                apply(secrets)
                done(true)
            } catch {
                flash("Écriture impossible : \(error)")
                done(false)
            }
        }
    }

    var existingNames: Set<String> {
        Set(entries.flatMap { VaultEdit.names($0.kind, $0.base) })
    }

    /// Valide et enregistre. Retourne un message d'erreur à afficher dans la fenêtre, ou nil si c'est parti.
    func save(pair: Bool, rawName: String, user: String, value: String, editing: Entry?) -> String? {
        let name = editing?.base ?? VaultEdit.normalize(rawName)
        if !Vault.isValidName(name) { return "Nom invalide : majuscules, chiffres et _" }
        if pair && VaultEdit.reservedSuffixes.contains(where: name.hasSuffix) { return "Donne le nom de base, sans _USER ni _PASSWORD" }
        if value.isEmpty { return "Valeur vide, rien n'a été enregistré" }
        let u = user.trimmingCharacters(in: .whitespaces)
        if pair && u.isEmpty { return "Identifiant vide" }
        let exported = editing?.exported ?? true     // modifier un secret hors environnement ne l'y fait pas entrer
        write({ all in
            if pair { VaultEdit.setLogin(&all, base: name, user: u, password: value) }
            else { VaultEdit.set(&all, name, value, exported: exported) }
        }) { [weak self] ok in
            if ok { self?.flash(pair || exported ? "\(name) enregistré · disponible dans les nouveaux terminaux" : "\(name) enregistré") }
        }
        sheet = nil
        return nil
    }

    func delete(_ e: Entry) {
        if e.kind == .aws && confirmAWS == nil { confirmAWS = e; return }
        confirmAWS = nil
        expanded.remove(e.base)
        let kind = e.kind, base = e.base
        trashCounter += 1
        let key = String(trashCounter)
        // L'instantané est pris DANS la transaction, sur les données verrouillées : fidèle au trousseau
        // (valeur, export, origine, jeton de session AWS compris), pas à ce qui était affiché.
        let box = SnapshotBox()
        write({ all in box.snaps = VaultEdit.delete(&all, kind, base) }) { [weak self] ok in
            guard let self, ok else { return }
            self.trash[key] = box.snaps
            Task { try? await Task.sleep(for: .seconds(60)); self.trash[key] = nil }   // la valeur ne reste pas en mémoire
        }
        flash("\(base) supprimé", seconds: 8, action: ("Annuler", key))
    }

    func undo(_ key: String) {
        if key == "bw-unlock" { toast = nil; sheet = .bwUnlock; return }
        toast = nil
        guard let snaps = trash.removeValue(forKey: key) else { flash("Trop tard : suppression définitive"); return }
        write({ all in VaultEdit.restore(&all, snaps) }) { [weak self] ok in if ok { self?.flash("Secret restauré") } }
    }

    // MARK: import .env

    func envPreview(_ text: String) -> (found: Int, replaced: Int) {
        let found = VaultEdit.parseEnv(text)
        let existing = existingNames
        return (found.count, found.filter { existing.contains($0.name) }.count)
    }

    func importEnv(_ text: String) {
        let found = VaultEdit.parseEnv(text)
        guard !found.isEmpty else { return }
        write({ all in for (n, v) in found { VaultEdit.set(&all, n, v) } }) { [weak self] ok in
            if ok { self?.flash("\(found.count) secret\(found.count > 1 ? "s" : "") importé\(found.count > 1 ? "s" : "")") }
        }
        sheet = nil
    }

    // MARK: groupe choisi à la main (state.json, pas le trousseau)

    var existingGroupLabels: [String] {
        Array(Set(taxonomy.group(entries).filter { $0.kind == .service || $0.kind == .project }.map(\.label)))
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    func groupState(of e: Entry) -> (auto: String, mine: String?) {
        var o = groupOverrides; o[e.base] = nil
        return (Taxonomy(entries, domains: domains, overrides: o).labelOf(e.base), groupOverrides[e.base])
    }

    /// Vide ou identique au classement automatique : rien à forcer.
    func setGroup(_ e: Entry, label: String?) {
        let (auto, _) = groupState(of: e)
        let l = String((label ?? "").trimmingCharacters(in: .whitespaces).prefix(60))
        func norm(_ s: String) -> String { s.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") }
        if l.isEmpty || norm(l) == norm(auto) { groupOverrides[e.base] = nil } else { groupOverrides[e.base] = l }
        let live = Set(entries.map(\.base))
        groupOverrides = groupOverrides.filter { live.contains($0.key) }     // purge les entrées disparues
        AppState.update(["groups": groupOverrides])
        taxonomy = Taxonomy(entries, domains: domains, overrides: groupOverrides)
        rebuild()
        sheet = nil
        flash(groupOverrides[e.base].map { "\(e.base) → \($0)" } ?? "\(e.base) : classement automatique")
    }
}
