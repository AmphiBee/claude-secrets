import Foundation
import SecretsCore


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

/// Un bloc de la liste de détail : un service (résultats de recherche) ou l'ensemble affiché.
struct EntrySection: Identifiable {
    let id: String
    let label: String
    let tag: String?          // PROJET / MANUEL
    let members: [Entry]
}

extension Entry: Identifiable { public var id: String { base } }

/// Une ligne de la barre latérale.
struct SideItem: Identifiable {
    let id: String
    let label: String
    let count: Int
    let tag: String?
    let symbol: String?       // collections seulement ; les services portent un monogramme
}

/// Ce que montre le volet de détail.
struct DetailContent {
    var title = ""
    var subtitle = ""
    var tag: String?
    var monogram: String?
    var sections: [EntrySection] = []
    var count: Int { sections.reduce(0) { $0 + $1.members.count } }
}

final class SnapshotBox: @unchecked Sendable { var snaps: [VaultSecret] = [] }

@MainActor
final class VaultModel: ObservableObject {
    enum Phase { case loading, ready, failed(String) }

    @Published var phase: Phase = .loading
    @Published var query = ""
    @Published var selection = "all"
    @Published var selectedEntry: String?
    @Published var revealed = Set<String>()
    @Published var toast: Toast?
    @Published var sheet: ActiveSheet?
    @Published var confirmAWS: Entry?
    @Published var syncing = false
    let auth = AuthGuard()
    @Published var entered = false
    var lastSync: Date?
    var autoErrorShown = false

    @Published private(set) var collections: [SideItem] = []
    @Published private(set) var sidebar: [(letter: String, items: [SideItem])] = []
    @Published private(set) var buckets: [SideItem] = []
    @Published private(set) var detail = DetailContent()
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
        #if DEBUG
        // Aides de développement (captures d'écran de la démo) : jamais dans une version de production.
        let env = ProcessInfo.processInfo.environment
        if let s = env["CLAUDE_SECRETS_UI_SELECT"] { selection = s }
        if let q = env["CLAUDE_SECRETS_UI_QUERY"] { query = q }
        #endif
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
        replayEntrance()
        if lastSync == nil { Task { try? await Task.sleep(for: .seconds(1.5)); autoSync() } }
    }

    /// Entrée orchestrée : les lignes apparaissent l'une après l'autre, une seule fois par ouverture.
    func replayEntrance() {
        guard !entered else { return }
        Task { try? await Task.sleep(for: .milliseconds(40)); entered = true }
    }

    /// Ferme tout et libère les valeurs : appelé quand la fenêtre est masquée.
    func hide() {
        query = ""; selectedEntry = nil; revealed = []; toast = nil; sheet = nil; confirmAWS = nil; entered = false; auth.reset()
    }

    /// Masquage prolongé : on relâche aussi les valeurs de la mémoire.
    func releaseValues() {
        hide(); store.dropCache(); trash = [:]; entries = []; lastSync = nil; detail = DetailContent(); collections = []; sidebar = []; buckets = []; taxonomy = Taxonomy([]); phase = .loading; loadedAt = nil
    }

    // MARK: affichage

    static let typeCollections: [(id: String, label: String, symbol: String, test: (Entry) -> Bool)] = [
        ("type:keys", "Clés et tokens", "key", { $0.kind == .single && $0.exported }),
        ("type:logins", "Identifiants", "person.text.rectangle", { $0.kind == .pair }),
        ("type:aws", "AWS", "cloud", { $0.kind == .aws }),
        ("type:offenv", "Hors environnement", "lock", { $0.kind == .single && !$0.exported }),
    ]

    func select(_ id: String) {
        selection = id; selectedEntry = nil; revealed = []
        rebuild()
    }

    func rebuild() {
        let groups = taxonomy.group(entries)
        // barre latérale : collections, puis services par lettre d'index, puis les « autres »
        var cols = [SideItem(id: "all", label: "Tous les secrets", count: entries.count, tag: nil, symbol: "tray.full")]
        for t in Self.typeCollections {
            let n = entries.filter(t.test).count
            if n > 0 { cols.append(SideItem(id: t.id, label: t.label, count: n, tag: nil, symbol: t.symbol)) }
        }
        collections = cols
        var byLetter: [(String, [SideItem])] = []
        buckets = []
        for g in groups {
            let item = SideItem(id: g.id, label: g.label, count: g.members.count, tag: tag(for: g), symbol: nil)
            if g.id.hasPrefix("bucket:") { buckets.append(item); continue }
            let l = indexLetter(g.label)
            if let i = byLetter.firstIndex(where: { $0.0 == l }) { byLetter[i].1.append(item) } else { byLetter.append((l, [item])) }
        }
        sidebar = byLetter.map { (letter: $0.0, items: $0.1) }

        // détail : la recherche prime ; sinon la sélection de la barre latérale
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let found = entries.filter { matches($0, q) || taxonomy.labelOf($0.base).lowercased().contains(q) }
            let secs = taxonomy.group(found).map { EntrySection(id: $0.id, label: $0.label, tag: tag(for: $0), members: $0.members) }
            detail = DetailContent(title: "Résultats", subtitle: plural(found.count, "entrée") + " pour « \(query.trimmingCharacters(in: .whitespaces)) »",
                                   tag: nil, monogram: nil, sections: secs)
            return
        }
        if let t = Self.typeCollections.first(where: { $0.id == selection }) {
            let m = entries.filter(t.test)
            detail = DetailContent(title: t.label, subtitle: plural(m.count, "entrée"), tag: nil, monogram: nil,
                                   sections: [EntrySection(id: t.id, label: "", tag: nil, members: m)])
        } else if let g = groups.first(where: { $0.id == selection }) {
            detail = DetailContent(title: g.label, subtitle: plural(g.members.count, "entrée"), tag: tag(for: g),
                                   monogram: g.id.hasPrefix("bucket:") ? nil : g.label,
                                   sections: [EntrySection(id: g.id, label: "", tag: nil, members: g.members)])
        } else {                                      // « Tous », ou une sélection qui n'existe plus
            if selection != "all" { selection = "all" }
            detail = DetailContent(title: "Tous les secrets", subtitle: plural(entries.count, "entrée"), tag: nil, monogram: nil,
                                   sections: [EntrySection(id: "all", label: "", tag: nil, members: entries)])
        }
    }

    private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n > 1 ? "s" : "")" }

    /// Lettre d'index d'un libellé (accents ignorés) ; « # » pour ce qui ne commence pas par une lettre.
    private func indexLetter(_ s: String) -> String {
        let f = s.folding(options: .diacriticInsensitive, locale: nil).uppercased().first
        return f.map { $0.isLetter ? String($0) : "#" } ?? "#"
    }

    private func matches(_ e: Entry, _ q: String) -> Bool {
        e.base.lowercased().contains(q) || (e.user?.lowercased().contains(q) ?? false)
    }

    private func tag(for g: Group) -> String? {
        g.manual ? "MANUEL" : (g.kind == .project ? "PROJET" : nil)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func label(of e: Entry) -> String { taxonomy.labelOf(e.base) }

    // MARK: actions

    func copy(_ e: Entry) {
        auth.authorize("copier une valeur du coffre", failed: { [weak self] in self?.flash($0) }) { [self] in doCopy(e) }
    }

    private func doCopy(_ e: Entry) {
        Clipboard.copy(e.value)
        flash(e.kind == .pair ? "Mot de passe copié · presse-papier vidé dans 45 s" : "Copié · presse-papier vidé dans 45 s")
    }

    func copyUser(_ e: Entry) {
        guard let u = e.user else { return }
        auth.authorize("copier un identifiant du coffre", failed: { [weak self] in self?.flash($0) }) { [self] in
            Clipboard.copy(u)
            flash("Identifiant copié · presse-papier vidé dans 45 s")
        }
    }

    /// Ouvre la fenêtre de modification : elle montre la valeur, donc elle passe par le même garde.
    func edit(_ e: Entry) {
        auth.authorize("modifier une valeur du coffre", failed: { [weak self] in self?.flash($0) }) { [self] in sheet = .edit(e) }
    }

    /// ⏎ dans la recherche : copie le premier résultat.
    func copyFirst() {
        let all = detail.sections.flatMap(\.members)
        if let id = selectedEntry, let e = all.first(where: { $0.base == id }) { copy(e) }
        else if let e = all.first { copy(e) }
    }

    func toggleReveal(_ e: Entry) {
        if revealed.contains(e.base) { revealed.remove(e.base); return }
        auth.authorize("afficher une valeur du coffre", failed: { [weak self] in self?.flash($0) }) { [self] in revealed.insert(e.base) }
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
