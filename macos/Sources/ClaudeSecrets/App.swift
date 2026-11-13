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
            MainActor.assumeIsolated { self?.releaseTask?.cancel(); self?.model?.load() }
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
        WindowGroup("Claude Secrets") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 480)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 680, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}   // ⌘N viendra avec l'écriture (étape 2)
        }
    }
}
