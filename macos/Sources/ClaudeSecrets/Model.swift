import Foundation
import SecretsCore

enum GroupMode: String { case service, type }

/// Section affichée : un groupe (service) ou une catégorie (mode « par type »).
struct Section: Identifiable {
    let id: String
    let label: String
    let tag: String?          // PROJET / MANUEL
    let members: [Entry]
}

@MainActor
final class VaultModel: ObservableObject {
    enum Phase { case loading, ready, failed(String) }

    @Published var phase: Phase = .loading
    @Published var query = ""
    @Published var expanded = Set<String>()
    @Published var revealed = Set<String>()
    @Published var mode: GroupMode = .service { didSet { if mode != oldValue { AppState.update(["group_by": mode.rawValue]) } } }
    @Published var toast: String?

    @Published private(set) var sections: [Section] = []
    private var entries: [Entry] = []
    private var taxonomy = Taxonomy([])
    private var loadedAt: Date?
    private let store: VaultStore

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

    private func apply(_ secrets: [VaultSecret]) {
        entries = grouped(secrets.map { ($0.name, $0.value, $0.exported) })
        let st = AppState.read()
        taxonomy = Taxonomy(entries, domains: st["domains"] as? [String: String] ?? [:],
                            overrides: st["groups"] as? [String: String] ?? [:])
        loadedAt = Date()
        phase = .ready
        rebuild()
    }

    /// Ferme tout et libère les valeurs : appelé quand la fenêtre est masquée.
    func hide() {
        query = ""; expanded = []; revealed = []; toast = nil
    }

    /// Masquage prolongé : on relâche aussi les valeurs de la mémoire.
    func releaseValues() {
        hide(); entries = []; sections = []; taxonomy = Taxonomy([]); phase = .loading; loadedAt = nil
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

    private func flash(_ text: String) {
        toast = text
        Task { try? await Task.sleep(for: .seconds(3)); if toast == text { toast = nil } }
    }
}
