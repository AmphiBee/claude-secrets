import Foundation
import LocalAuthentication
import SecretsCore

/// Verrouillage de l'app : Touch ID (ou le mot de passe du Mac) avant d'afficher ou de copier une valeur.
/// Réglable, désactivé par défaut. Une authentification réussie vaut 60 s, puis elle est redemandée.
@MainActor
final class AuthGuard {
    static let validFor: TimeInterval = 60
    private var until: Date?

    var enabled: Bool { (AppState.read()["touch_id"] as? Bool) ?? false }
    func setEnabled(_ on: Bool) { AppState.update(["touch_id": on]); until = nil }
    func reset() { until = nil }

    /// Exécute `action` si l'accès est autorisé ; sinon demande l'authentification. `failed` : message à afficher.
    func authorize(_ reason: String, failed: @escaping @MainActor (String) -> Void, then action: @escaping @MainActor () -> Void) {
        if !enabled || (until.map { $0 > Date() } ?? false) { action(); return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            failed("Authentification indisponible sur ce Mac : désactive-la dans les Réglages")
            return
        }
        Task { @MainActor in
            let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
            if ok { until = Date().addingTimeInterval(Self.validFor); action() } else { failed("Authentification annulée") }
        }
    }
}
