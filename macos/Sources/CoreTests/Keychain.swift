// Tests d'intégration du trousseau : service de test uniquement, session graphique requise.
//   swift run core-tests keychain      (ou Tools/run-keychain-tests.sh)
import Foundation
import Security
import SecretsCore

private let reference = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/macos/reference").path

private func python(_ service: String, _ code: String) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-c", "import sys; sys.path.insert(0, \(reference.debugDescription)); import _keychain as k\n" + code]
    p.environment = ["CLAUDE_SECRETS_SERVICE": service, "HOME": NSHomeDirectory()]
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

func runKeychainTests() {
    let service = "zztest-core-\(getpid())"
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("zztest-cache-\(getpid()).env")
    defer {
        try? FileManager.default.removeItem(at: cache)
        if SecItemDeleteService(service) != 0 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["delete-generic-password", "-s", service]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }
    let store = KeychainVaultStore(service: service, cacheURL: cache)
    print("Trousseau (service \(service))")

    check("coffre absent = vide", (try? store.load())?.isEmpty == true)
    let multi = "ligne1\nligne2 é ✓ 'quote'"
    do {
        try store.transaction { v in
            VaultEdit.set(&v, "ZZTEST_A", multi, source: "bitwarden:Dossier")
            VaultEdit.set(&v, "ZZTEST_B", "b", exported: false)
            VaultEdit.set(&v, "_BW_SESSION", "reservee", exported: false)
        }
    } catch { check("écriture : \(error)", false) }
    let loaded = (try? store.load()) ?? []
    check("relecture à l'identique (multi-ligne, Unicode, source, export)",
          loaded.first { $0.name == "ZZTEST_A" } == VaultSecret(name: "ZZTEST_A", value: multi, exported: true, source: "bitwarden:Dossier")
          && loaded.first { $0.name == "ZZTEST_B" }?.exported == false)
    check("nom réservé invisible à la lecture", !loaded.contains { $0.name == "_BW_SESSION" })
    let attrs = try? FileManager.default.attributesOfItem(atPath: cache.path)
    check("cache en 0600", (attrs?[.posixPermissions] as? Int) == 0o600)
    check("cache : seul le secret exporté, échappé pour le shell",
          (try? String(contentsOf: cache, encoding: .utf8)) == "export ZZTEST_A=\(ShellCache.quote(multi))\n")

    let (rc, out) = python(service, """
    v = k._load(); print(len(v), v["ZZTEST_A"]["source"], len(v["ZZTEST_A"]["value"]), v["ZZTEST_A"]["value"].count("\\n"), "_BW_SESSION" in v)
    """)
    check("la CLI (shim Python) relit ce que Swift a écrit, réservé compris", rc == 0 && out.contains("3 bitwarden:Dossier \(multi.unicodeScalars.count) 1 True"))

    let (rc2, _) = python(service, """
    k._lock(); v = k._load(); v["ZZTEST_FROMPY"] = {"value": "py", "export": "1", "source": "local"}
    k._state["dirty"] = True; k._flush()
    """)
    let afterPy = (try? store.load()) ?? []
    check("Swift relit ce que la CLI a écrit, sans rien perdre",
          rc2 == 0 && afterPy.map(\.name) == ["ZZTEST_A", "ZZTEST_B", "ZZTEST_FROMPY"])

    // Cache de lecture : une seule lecture de la valeur tant que l'élément n'a pas changé.
    print("Cache de lecture (date de modification)")
    Thread.sleep(forTimeInterval: 2.2)                       // l'élément est stable : le cache devient fiable
    let c1 = (try? store.load()) ?? []
    let t0 = Date(); let c2 = (try? store.load()) ?? []; let dt = Date().timeIntervalSince(t0)
    check("deuxième lecture servie par le cache (\(Int(dt * 1000)) ms)", c1 == c2 && dt < 0.2)
    _ = python(service, """
    k._lock(); v = k._load(); v["ZZTEST_APRES_CACHE"] = {"value": "n", "export": "1", "source": "local"}
    k._state["dirty"] = True; k._flush()
    """)
    check("écriture externe juste après : la lecture suivante la voit (cache invalidé par la date)",
          ((try? store.load()) ?? []).contains { $0.name == "ZZTEST_APRES_CACHE" })

    // Concurrence : 3 écrivains Python et 3 écrivains Swift en même temps, aucune mise à jour perdue.
    print("Concurrence (3 processus Python + 3 fils Swift)")
    let group = DispatchGroup()
    let status = NSLock(); nonisolated(unsafe) var pyOK = true
    for n in 0..<3 {
        DispatchQueue.global().async(group: group) {
            let (rc, _) = python(service, """
            k._lock(); v = k._load()
            for i in range(4): v[f"ZZTEST_PY\(n)_{i}"] = {"value": "p", "export": "1", "source": "local"}
            k._state["dirty"] = True; k._flush()
            """)
            status.lock(); if rc != 0 { pyOK = false }; status.unlock()
        }
        DispatchQueue.global().async(group: group) {
            for i in 0..<4 { _ = try? store.transaction { VaultEdit.set(&$0, "ZZTEST_SW\(n)_\(i)", "s") } }
        }
    }
    group.wait()
    let final = (try? store.load()) ?? []
    check("aucun écrivain en erreur", pyOK)
    check("aucune mise à jour perdue : 4 + 12 Python + 12 Swift = \(final.count)", final.count == 4 + 12 + 12)
    let ids = Set(final.map(\.name))
    check("tous les noms attendus présents",
          (0..<3).allSatisfy { n in (0..<4).allSatisfy { ids.contains("ZZTEST_PY\(n)_\($0)") && ids.contains("ZZTEST_SW\(n)_\($0)") } })

    check("suppression + annulation sur le vrai trousseau de test", {
        var snaps: [VaultSecret] = []
        _ = try? store.transaction { snaps = VaultEdit.delete(&$0, .single, "ZZTEST_A") }
        let gone = !((try? store.load()) ?? []).contains { $0.name == "ZZTEST_A" }
        _ = try? store.transaction { VaultEdit.restore(&$0, snaps) }
        let back = ((try? store.load()) ?? []).first { $0.name == "ZZTEST_A" }
        return gone && back?.source == "bitwarden:Dossier" && back?.value == multi
    }())
}

private func SecItemDeleteService(_ s: String) -> Int32 {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s]
    return SecItemDelete(q as CFDictionary)
}
