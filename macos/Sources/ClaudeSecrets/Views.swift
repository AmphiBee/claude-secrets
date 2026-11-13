import SwiftUI
import SecretsCore

let redaction = String(repeating: "▇", count: 9)   // de longueur fixe : ne trahit pas la taille du secret

extension VaultModel { var isReady: Bool { if case .ready = phase { return true } else { return false } } }

/// Le sceau : seul endroit où le cuivre sert d'ornement.
struct Seal: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.965, green: 0.663, blue: 0.455), Theme.copperDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "key.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.spark)
                .rotationEffect(.degrees(-45))
        }
        .frame(width: size, height: size).accessibilityHidden(true)
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

struct Monogram: View {
    let label: String
    var size: CGFloat = 28
    var body: some View {
        let (bg, border, fg) = Theme.tone(label)
        let ch = label.folding(options: .diacriticInsensitive, locale: nil).uppercased().first.map(String.init) ?? "?"
        Text(ch).font(Theme.title(size * 0.5)).foregroundStyle(fg)
            .frame(width: size, height: size).background(bg, in: Circle())
            .overlay(Circle().stroke(border, lineWidth: 1)).accessibilityHidden(true)
    }
}

/// Tampon : l'état est dit en toutes lettres, jamais par la couleur seule.
struct Stamp: View {
    let text: String
    var small = false
    var body: some View {
        Text(text).font(.system(size: small ? 8 : 9, weight: .bold)).tracking(small ? 0.8 : 1.2).foregroundStyle(Theme.copper)
            .padding(.horizontal, small ? 4 : 5).padding(.vertical, small ? 1 : 2)
            .overlay(Rectangle().stroke(Theme.copper, lineWidth: 1))
    }
}

struct EntryRow: View {
    @ObservedObject var model: VaultModel
    let entry: Entry
    final class Hover: ObservableObject { @Published var on = false }
    @StateObject private var hover = Hover()

    @ViewBuilder private var actions: some View {
        Button("Copier la valeur") { model.copy(entry) }
        if entry.kind != .single { Button("Copier l'identifiant") { model.copyUser(entry) } }
        Button(model.revealed.contains(entry.base) ? "Masquer" : "Afficher") { model.toggleReveal(entry) }
        Divider()
        if entry.kind != .aws { Button("Modifier…") { model.edit(entry) } }
        Button("Changer de groupe…") { model.sheet = .group(entry) }
        Divider()
        Button("Supprimer", role: .destructive) { model.delete(entry) }
    }

    var body: some View {
        let shown = model.revealed.contains(entry.base)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.base).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.ink).lineLimit(1)
                    if entry.kind == .aws { Text("AWS").font(.caption).foregroundStyle(Theme.inkSoft) }
                }
                if entry.user != nil || (!entry.exported && entry.kind != .aws) {
                    HStack(spacing: 8) {
                        if let u = entry.user { Text(u).lineLimit(1) }
                        if !entry.exported && entry.kind != .aws {
                            Label("hors environnement", systemImage: "lock.fill").lineLimit(1).fixedSize()
                        }
                    }
                    .font(.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            Spacer(minLength: 8)
            Text(shown ? entry.value : redaction).font(.system(.callout, design: .monospaced))
                .foregroundStyle(shown ? Theme.ink : Theme.inkSoft).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .trailing)
                .accessibilityLabel(shown ? "valeur affichée" : "valeur masquée")
            // Actions au survol ou à la sélection (comme Mail) ; elles restent dans l'arbre d'accessibilité.
            HStack(spacing: 8) {
                Button { model.toggleReveal(entry) } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                    .help(shown ? "Masquer" : "Afficher").accessibilityLabel(shown ? "Masquer la valeur" : "Afficher la valeur")
                Button { model.copy(entry) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copier (effacé après 45 s)").accessibilityLabel("Copier la valeur")
                Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Plus d'actions").accessibilityLabel("Plus d'actions")
            }
            .opacity(hover.on || model.selectedEntry == entry.base || shown ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hover.on)
        }
        .onHover { hover.on = $0 }
        .buttonStyle(.borderless).foregroundStyle(Theme.copper)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { actions }
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
            TextField("Dossier à synchroniser", text: $f.folder, prompt: Text("Vide = tout le coffre · / = éléments sans dossier")).textFieldStyle(.roundedBorder)
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
