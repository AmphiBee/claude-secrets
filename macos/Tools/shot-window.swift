// Capture UNIQUEMENT la fenêtre d'une application (jamais l'écran entier) :
//   swift Tools/shot-window.swift "<nom du processus>" sortie.png
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3 else { print("usage : shot-window <processus> <sortie.png>"); exit(2) }
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let wins = list.filter { ($0[kCGWindowOwnerName as String] as? String) == args[1] && ($0[kCGWindowLayer as String] as? Int) == 0 }
// la plus grande fenêtre du processus
guard let w = wins.max(by: { area($0) < area($1) }), let id = w[kCGWindowNumber as String] as? Int else {
    print("aucune fenêtre visible pour « \(args[1]) »"); exit(1)
}
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-o", "-l", String(id), args[2]]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK : \(args[2])" : "screencapture a échoué")
