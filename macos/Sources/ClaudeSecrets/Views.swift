import SwiftUI
import SecretsCore

let redaction = String(repeating: "▇", count: 9)   // de longueur fixe : ne trahit pas la taille du secret

struct ContentView: View {
    @ObservedObject var model: VaultModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, searchFocused: $searchFocused)
            Rectangle().fill(Theme.rule).frame(height: 1)
            switch model.phase {
            case .loading:
                Status(symbol: "hourglass", text: "Ouverture du coffre…",
                       detail: "La première lecture du trousseau peut prendre quelques secondes.")
            case .failed(let msg):
                VStack(spacing: 12) {
                    Status(symbol: "lock.slash", text: "Le coffre reste fermé.", detail: msg)
                    Button("Réessayer") { model.load(force: true) }
                }
            case .ready:
                if model.sections.isEmpty {
                    Status(symbol: "tray", text: model.isSearching ? "Rien ne correspond." : "Le coffre est vide.",
                           detail: nil)
                } else {
                    SectionList(model: model)
                }
            }
        }
        .background(Theme.paper)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.ink).foregroundStyle(Theme.paper)
                    .padding(.bottom, 16).transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .onAppear { model.load() }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true))
    }
}

struct Header: View {
    @ObservedObject var model: VaultModel
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Seal()
                Text("Claude Secrets").font(Theme.title(22)).foregroundStyle(Theme.ink)
                Spacer()
                Picker("Classement", selection: $model.mode) {
                    Text("Par service").tag(GroupMode.service)
                    Text("Par type").tag(GroupMode.type)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                .onChange(of: model.mode) { model.rebuild() }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSoft)
                TextField("Chercher un secret, un identifiant, un service", text: $model.query)
                    .textFieldStyle(.plain).focused(searchFocused)
                    .onSubmit { model.copyFirst() }
                    .onChange(of: model.query) { model.rebuild() }
                if model.isSearching {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.inkSoft).help("Effacer la recherche")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.paperRaised).overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        }
        .padding(16)
    }
}

/// Le sceau : seul endroit où le cuivre sert d'ornement.
struct Seal: View {
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.965, green: 0.663, blue: 0.455), Theme.copperDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "key.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.spark)
                .rotationEffect(.degrees(-45))
        }
        .frame(width: 30, height: 30).accessibilityHidden(true)
    }
}

struct Status: View {
    let symbol: String, text: String, detail: String?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Theme.inkSoft)
            Text(text).font(Theme.title(17)).foregroundStyle(Theme.ink)
            if let detail { Text(detail).font(.callout).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center) }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Lettre d'index d'un groupe (les accents sont ignorés) ; "" pour les groupes « Autres ».
func indexLetter(_ s: Section) -> String {
    if s.id.hasPrefix("bucket:") || s.id.hasPrefix("type:") { return "" }
    let f = s.label.folding(options: .diacriticInsensitive, locale: nil).uppercased().first
    return f.map { $0.isLetter ? String($0) : "#" } ?? "#"
}

struct SectionList: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.sections.enumerated()), id: \.element.id) { i, s in
                    let letter = indexLetter(s)
                    let first = !letter.isEmpty && (i == 0 || indexLetter(model.sections[i - 1]) != letter)
                    GroupRow(model: model, section: s, letter: first ? letter : nil)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
            }
        }
    }
}

struct GroupRow: View {
    @ObservedObject var model: VaultModel
    let section: Section
    let letter: String?

    var body: some View {
        let open = model.isExpanded(section)
        VStack(spacing: 0) {
            Button { model.toggle(section) } label: {
                HStack(spacing: 12) {
                    Text(letter ?? "").font(Theme.title(15)).foregroundStyle(Theme.copper).frame(width: 18)
                    Monogram(label: section.label)
                    Text(section.label).font(Theme.title(16)).foregroundStyle(Theme.ink)
                    if let tag = section.tag { Stamp(text: tag) }
                    Spacer()
                    Text("\(section.members.count)").monospacedDigit().foregroundStyle(Theme.inkSoft)
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.inkSoft).imageScale(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.label), \(section.members.count) entrées")
            .accessibilityValue(open ? "ouvert" : "fermé")
            if open {   // le contenu n'est construit qu'à l'ouverture
                VStack(spacing: 0) {
                    ForEach(section.members, id: \.base) { EntryRow(model: model, entry: $0) }
                }
                .padding(.leading, 48).padding(.bottom, 6)
            }
        }
    }
}

struct Monogram: View {
    let label: String
    var body: some View {
        let (bg, border, fg) = Theme.tone(label)
        let ch = label.folding(options: .diacriticInsensitive, locale: nil).uppercased().first.map(String.init) ?? "?"
        Text(ch).font(Theme.title(14)).foregroundStyle(fg)
            .frame(width: 28, height: 28).background(bg, in: Circle())
            .overlay(Circle().stroke(border, lineWidth: 1)).accessibilityHidden(true)
    }
}

/// Tampon : l'état est dit en toutes lettres, jamais par la couleur seule.
struct Stamp: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.copper)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(Rectangle().stroke(Theme.copper, lineWidth: 1))
    }
}

struct EntryRow: View {
    @ObservedObject var model: VaultModel
    let entry: Entry

    var body: some View {
        let shown = model.revealed.contains(entry.base)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.base).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.ink)
                    if !entry.exported && entry.kind != .aws {
                        Label("hors environnement", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                            .font(.caption).foregroundStyle(Theme.inkSoft)
                    }
                    if entry.kind == .aws { Text("AWS").font(.caption).foregroundStyle(Theme.inkSoft) }
                }
                if let u = entry.user {
                    Text(u).font(.caption).foregroundStyle(Theme.inkSoft).textSelection(.disabled)
                }
            }
            Spacer(minLength: 8)
            Text(shown ? entry.value : redaction).font(.system(.callout, design: .monospaced))
                .foregroundStyle(shown ? Theme.ink : Theme.inkSoft).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .trailing)
                .accessibilityLabel(shown ? "valeur affichée" : "valeur masquée")
            Button { model.toggleReveal(entry) } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                .help(shown ? "Masquer" : "Afficher").accessibilityLabel(shown ? "Masquer la valeur" : "Afficher la valeur")
            if entry.kind != .single {
                Button { model.copyUser(entry) } label: { Image(systemName: "person") }
                    .help("Copier l'identifiant").accessibilityLabel("Copier l'identifiant")
            }
            Button { model.copy(entry) } label: { Image(systemName: "doc.on.doc") }
                .help("Copier (effacé après 45 s)").accessibilityLabel("Copier la valeur")
        }
        .buttonStyle(.borderless).foregroundStyle(Theme.copper)
        .padding(.vertical, 5).padding(.trailing, 16)
    }
}
