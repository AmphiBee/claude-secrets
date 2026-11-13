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
                HStack(spacing: 14) {
                    Text(t.text).font(.callout)
                    if let label = t.actionLabel, let key = t.actionKey {
                        Button(label) { model.undo(key) }.buttonStyle(.plain).fontWeight(.bold)
                            .underline().foregroundStyle(Theme.toastAccent)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.ink).foregroundStyle(Theme.paper)
                .padding(.bottom, 16).transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .onAppear { model.load(); model.replayEntrance() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newSecret: SecretSheet(model: model, editing: nil)
            case .edit(let e): SecretSheet(model: model, editing: e)
            case .importEnv: ImportSheet(model: model)
            case .group(let e): GroupSheet(model: model, entry: e)
            case .bwSetup: BwSetupSheet(model: model)
            case .bwUnlock: BwUnlockSheet(model: model)
            case .awsImport: AwsImportSheet(model: model)
            }
        }
        .confirmationDialog("Supprimer ce profil AWS ?", isPresented: Binding(
            get: { model.confirmAWS != nil }, set: { if !$0 { model.confirmAWS = nil } }), titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { if let e = model.confirmAWS { model.delete(e) } }
            Button("Annuler", role: .cancel) { model.confirmAWS = nil }
        } message: {
            Text("Les clés seront retirées du trousseau. Pense à retirer aussi la ligne credential_process de ~/.aws/config.")
        }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true))
    }
}

extension VaultModel { var isReady: Bool { if case .ready = phase { return true } else { return false } } }

struct Header: View {
    @ObservedObject var model: VaultModel
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Seal()
                Text("Claude Secrets").font(Theme.title(22)).foregroundStyle(Theme.ink)
                Spacer()
                Button { model.syncNow() } label: {
                    if model.syncing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .help("Synchroniser Bitwarden (⌘R)").accessibilityLabel("Synchroniser Bitwarden")
                .disabled(!model.isReady || model.syncing)
                Button { model.sheet = .newSecret } label: { Label("Nouveau", systemImage: "plus") }
                    .help("Nouveau secret (⌘N)").disabled(!model.isReady)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.sections.enumerated()), id: \.element.id) { i, s in
                    let letter = indexLetter(s)
                    let first = !letter.isEmpty && (i == 0 || indexLetter(model.sections[i - 1]) != letter)
                    GroupRow(model: model, section: s, letter: first ? letter : nil)
                        .opacity(model.entered || reduceMotion ? 1 : 0)
                        .offset(y: model.entered || reduceMotion ? 0 : 8)
                        // décélération exponentielle, jamais de rebond ; seules les 14 premières lignes sont échelonnées
                        .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.55).delay(Double(min(i, 14)) * 0.03),
                                   value: model.entered)
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
            Menu {
                if entry.kind != .aws { Button("Modifier…") { model.edit(entry) } }
                if model.mode == .service { Button("Changer de groupe…") { model.sheet = .group(entry) } }
                Divider()
                Button("Supprimer", role: .destructive) { model.delete(entry) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Plus d'actions").accessibilityLabel("Plus d'actions")
        }
        .buttonStyle(.borderless).foregroundStyle(Theme.copper)
        .padding(.vertical, 5).padding(.trailing, 16)
    }
}


// MARK: - Fenêtres de saisie

struct SheetFrame<Content: View>: View {
    let title: String, confirm: String
    var enabled = true
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.title(20)).foregroundStyle(Theme.ink)
            content
            HStack {
                Spacer()
                Button("Annuler", action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirm, action: onConfirm).keyboardShortcut(.defaultAction).disabled(!enabled)
                    .tint(Theme.copper)
            }
        }
        .padding(20).frame(width: 440).background(Theme.paper)
    }
}

struct SecretSheet: View {
    @ObservedObject var model: VaultModel
    let editing: Entry?
    final class Form: ObservableObject {
        @Published var pair = false
        @Published var name = ""
        @Published var user = ""
        @Published var value = ""
        @Published var error: String?
    }
    @StateObject private var f = Form()

    private var normalized: String { VaultEdit.normalize(f.name) }
    private var replaces: Bool { editing == nil && !normalized.isEmpty && model.existingNames.contains(normalized + (f.pair ? "_USER" : "")) }

    var body: some View {
        SheetFrame(title: editing == nil ? "Nouveau secret" : "Modifier \(editing!.base)",
                   confirm: "Enregistrer", onConfirm: submit, onCancel: { model.sheet = nil }) {
            if editing == nil {
                Picker("Type", selection: $f.pair) {
                    Text("Clé ou token").tag(false)
                    Text("Identifiant + mot de passe").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                TextField("Nom (ex. MON_SERVICE_API_KEY)", text: $f.name).textFieldStyle(.roundedBorder)
                if !normalized.isEmpty {
                    Text(f.pair ? "Variables : \(normalized)_USER et \(normalized)_PASSWORD" : "Variable : \(normalized)")
                        .font(.caption).foregroundStyle(Theme.inkSoft)
                }
                if replaces { Text("Ce nom existe déjà : sa valeur sera remplacée.").font(.caption).foregroundStyle(Theme.copper) }
            }
            if f.pair { TextField("Identifiant", text: $f.user).textFieldStyle(.roundedBorder) }
            SecureField(f.pair ? "Mot de passe" : "Valeur", text: $f.value).textFieldStyle(.roundedBorder)
            if let error = f.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.copper) }
        }
        .onAppear {
            if let e = editing { f.pair = e.kind == .pair; f.user = e.user ?? ""; f.value = e.value }
        }
    }

    private func submit() {
        f.error = model.save(pair: f.pair, rawName: f.name, user: f.user, value: f.value, editing: editing)
    }
}

struct ImportSheet: View {
    @ObservedObject var model: VaultModel
    final class Form: ObservableObject { @Published var text = "" }
    @StateObject private var f = Form()
    private var text: String { f.text }

    private var hint: String {
        let p = model.envPreview(text)
        if p.found == 0 { return "Aucune ligne NOM=valeur reconnue." }
        var t = "\(p.found) secret\(p.found > 1 ? "s" : "") détecté\(p.found > 1 ? "s" : "")"
        if p.replaced > 0 { t += ", dont \(p.replaced) remplacé\(p.replaced > 1 ? "s" : "")" }
        return t
    }

    var body: some View {
        SheetFrame(title: "Importer un .env", confirm: "Importer", enabled: model.envPreview(text).found > 0,
                   onConfirm: { model.importEnv(text) }, onCancel: { model.sheet = nil }) {
            Text("Colle le contenu du fichier : une ligne NOM=valeur par secret. Les secrets existants du même nom sont remplacés.")
                .font(.callout).foregroundStyle(Theme.inkSoft)
            TextEditor(text: $f.text).font(.system(.callout, design: .monospaced)).frame(height: 170)
                .scrollContentBackground(.hidden).background(Theme.paperRaised)
                .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
            Text(hint).font(.caption).foregroundStyle(Theme.inkSoft)
        }
    }
}

struct GroupSheet: View {
    @ObservedObject var model: VaultModel
    let entry: Entry
    final class Form: ObservableObject { @Published var label = "" }
    @StateObject private var f = Form()
    private var label: String { f.label }

    var body: some View {
        let st = model.groupState(of: entry)
        SheetFrame(title: "Groupe de \(entry.base)", confirm: "Enregistrer",
                   onConfirm: { model.setGroup(entry, label: label) }, onCancel: { model.sheet = nil }) {
            Text("Choisis un groupe existant ou saisis un nouveau nom. « Automatique » revient au classement d'après le nom.")
                .font(.callout).foregroundStyle(Theme.inkSoft)
            Picker("Groupes existants", selection: $f.label) {
                Text("—").tag(label)
                ForEach(model.existingGroupLabels, id: \.self) { Text($0).tag($0) }
            }
            TextField("Nom du groupe", text: $f.label).textFieldStyle(.roundedBorder)
            if st.mine != nil {
                Button("Automatique") { model.setGroup(entry, label: nil) }
            }
        }
        .onAppear { f.label = st.mine ?? st.auto }
    }
}


struct BwSetupSheet: View {
    @ObservedObject var model: VaultModel
    final class Form: ObservableObject {
        @Published var server = ""
        @Published var email = ""
        @Published var password = ""
        @Published var code = ""
        @Published var folder = bwDefaultFolder
        @Published var error: String?
        @Published var busy = false
    }
    @StateObject private var f = Form()

    var body: some View {
        SheetFrame(title: "Configurer Bitwarden", confirm: f.busy ? "Connexion…" : "Se connecter",
                   enabled: !f.busy && !f.password.isEmpty && (!f.email.isEmpty || model.bwConfigured),
                   onConfirm: submit, onCancel: { model.sheet = nil }) {
            Text("Le mot de passe maître n'est pas conservé : seule la clé de session l'est, chiffrée dans le trousseau.")
                .font(.callout).foregroundStyle(Theme.inkSoft)
            TextField("Serveur (vide = bitwarden.com)", text: $f.server).textFieldStyle(.roundedBorder)
            TextField("Adresse e-mail", text: $f.email).textFieldStyle(.roundedBorder).textContentType(.username)
            SecureField("Mot de passe maître", text: $f.password).textFieldStyle(.roundedBorder)
            TextField("Code à deux facteurs (si demandé)", text: $f.code).textFieldStyle(.roundedBorder)
            TextField("Dossier à synchroniser", text: $f.folder).textFieldStyle(.roundedBorder)
            if let e = f.error { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.copper) }
        }
        .onAppear {
            let c = BitwardenClient.conf()
            f.server = c["server"] as? String ?? ""; f.email = c["email"] as? String ?? ""
            f.folder = model.bwFolder
        }
    }

    private func submit() {
        f.busy = true; f.error = nil
        let pwd = f.password
        f.password = ""     // le champ est vidé tout de suite : le mot de passe ne reste pas dans l'interface
        model.setupBitwarden(server: f.server, email: f.email, password: pwd, code: f.code, folder: f.folder) { err in
            f.busy = false; f.error = err
        }
    }
}

struct BwUnlockSheet: View {
    @ObservedObject var model: VaultModel
    final class Form: ObservableObject { @Published var password = "" }
    @StateObject private var f = Form()

    var body: some View {
        SheetFrame(title: "Coffre Bitwarden verrouillé", confirm: "Déverrouiller", enabled: !f.password.isEmpty,
                   onConfirm: {
                       let p = f.password; f.password = ""
                       model.unlockBitwarden(password: p) { _ in }
                   }, onCancel: { model.sheet = nil }) {
            Text("Saisis ton mot de passe maître pour déverrouiller. Il n'est pas conservé : seule la clé de session l'est, chiffrée dans le trousseau.")
                .font(.callout).foregroundStyle(Theme.inkSoft)
            SecureField("Mot de passe maître", text: $f.password).textFieldStyle(.roundedBorder)
        }
    }
}

struct AwsImportSheet: View {
    @ObservedObject var model: VaultModel
    final class Form: ObservableObject { @Published var activate = false }
    @StateObject private var f = Form()
    private var count: Int { Aws.profiles().count }

    var body: some View {
        SheetFrame(title: "Importer les profils AWS", confirm: "Importer", enabled: count > 0,
                   onConfirm: { model.importAws(activate: f.activate); model.sheet = nil }, onCancel: { model.sheet = nil }) {
            Text(count == 0 ? "Aucun profil exploitable dans ~/.aws/credentials."
                 : "\(count) profil\(count > 1 ? "s" : "") trouvé\(count > 1 ? "s" : "") dans ~/.aws/credentials. Ils iront dans le trousseau, hors environnement.")
                .font(.callout).foregroundStyle(Theme.inkSoft)
            Toggle("Activer credential_process pour l'AWS CLI", isOn: $f.activate)
            if f.activate {
                Text("~/.aws/config recevra une ligne credential_process, et ~/.aws/credentials sera renommé en credentials.disabled (il avait priorité). Une copie datée de chaque fichier est faite avant.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
