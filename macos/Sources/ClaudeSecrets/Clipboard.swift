import AppKit

/// Presse-papier : copie marquée confidentielle, effacée au bout de 45 s si elle est encore la nôtre.
@MainActor
enum Clipboard {
    static let clearAfter: TimeInterval = 45
    private static var pending: Task<Void, Never>?

    static func copy(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        // Les gestionnaires de presse-papier respectent ce type et n'archivent pas la copie.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let mine = pb.changeCount
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(clearAfter))
            guard !Task.isCancelled else { return }
            if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() }
        }
    }
}
