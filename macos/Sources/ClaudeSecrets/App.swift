import SwiftUI
import AppKit

/// Fermer = masquer : la fenêtre vide l'affichage ; valeurs relâchées après 5 min, sortie après 20 min.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: VaultModel?
    private var releaseTask: Task<Void, Never>?
    static let releaseAfter: Duration = .seconds(5 * 60)
    static let quitAfter: Duration = .seconds(20 * 60)

    func applicationDidFinishLaunching(_ n: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? NSWindow)?.canBecomeMain == true else { return }
            MainActor.assumeIsolated { self?.windowHidden() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseTask?.cancel(); self?.model?.load(); self?.model?.replayEntrance(); self?.model?.autoSync() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    private func windowHidden() {
        model?.hide()
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: Self.releaseAfter)
            guard !Task.isCancelled else { return }
            model?.releaseValues()
            try? await Task.sleep(for: Self.quitAfter - Self.releaseAfter)
            guard !Task.isCancelled else { return }
            NSApp.terminate(nil)
        }
    }
}

@main
struct ClaudeSecretsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = VaultModel()

    var body: some Scene {
        WindowGroup("Claude Secrets", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 480)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 680, height: 760)
        .commands {
            CommandMenu("Bitwarden") {
                Button("Synchroniser") { model.syncNow() }.keyboardShortcut("r").disabled(!model.isReady || model.syncing)
                Button("Configurer…") { model.sheet = .bwSetup }.disabled(!model.isReady)
                Button("Déverrouiller…") { model.sheet = .bwUnlock }.disabled(!model.isReady || !model.bwConfigured)
                Toggle("Synchronisation automatique", isOn: Binding(get: { model.autoSyncEnabled }, set: { model.setAutoSync($0) }))
                Divider()
                Button("Se déconnecter") { model.bwLogout() }.disabled(!model.bwConfigured)
                Divider()
                Button("Importer les profils AWS…") { model.sheet = .awsImport }.disabled(!model.isReady)
            }
            CommandGroup(replacing: .newItem) {
                Button("Nouveau secret…") { model.sheet = .newSecret }.keyboardShortcut("n").disabled(!model.isReady)
                Button("Importer un .env…") { model.sheet = .importEnv }.keyboardShortcut("i").disabled(!model.isReady)
            }
        }
        Settings { SettingsView(model: model) }
    }
}
