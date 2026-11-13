import SwiftUI
import SecretsCore

/// Réglages (⌘,) : sécurité, Bitwarden, AWS. Les actions qui ouvrent une fenêtre de saisie rouvrent la fenêtre principale.
struct SettingsView: View {
    @ObservedObject var model: VaultModel
    @Environment(\.openWindow) private var openWindow
    final class Draft: ObservableObject { @Published var folder = "" }
    @StateObject private var f = Draft()

    private func show(_ sheet: ActiveSheet) {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) { openWindow(id: "main") }
        model.sheet = sheet
    }

    var body: some View {
        SwiftUI.Form {
            SwiftUI.Section("Sécurité") {
                Toggle("Demander Touch ID avant d'afficher ou de copier une valeur", isOn: Binding(
                    get: { model.auth.enabled }, set: { model.auth.setEnabled($0); model.objectWillChange.send() }))
                Text("Le mot de passe du Mac sert de repli. Une authentification vaut 60 secondes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Fermer la fenêtre masque tout. Les valeurs sont relâchées de la mémoire après 5 minutes, et l'application quitte après 20.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Bitwarden") {
                if model.bwConfigured {
                    LabeledContent("Compte", value: model.bwEmail ?? "")
                    TextField("Dossier synchronisé", text: $f.folder, prompt: Text("Vide = tout le coffre · / = éléments sans dossier"))
                        .onSubmit { BitwardenClient.setConf(["folder": f.folder.trimmingCharacters(in: .whitespaces)]); model.objectWillChange.send() }
                    Toggle("Synchronisation automatique", isOn: Binding(
                        get: { model.autoSyncEnabled }, set: { model.setAutoSync($0) }))
                    HStack {
                        Button("Reconfigurer…") { show(.bwSetup) }
                        Button("Se déconnecter", role: .destructive) { model.bwLogout() }
                    }
                } else {
                    Text("Aucun compte connecté.").foregroundStyle(.secondary)
                    Button("Configurer…") { show(.bwSetup) }
                }
            }
            SwiftUI.Section("AWS") {
                Button("Importer les profils AWS…") { show(.awsImport) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { f.folder = model.bwFolder }
    }
}
