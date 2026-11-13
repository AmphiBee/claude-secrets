// Spike étape 0 : lecture/écriture de l'élément de trousseau depuis Swift, avec mesure du temps.
// Garde-fou : refuse de tourner hors d'un service de test (jamais le vrai coffre).
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
guard let service = env["CLAUDE_SECRETS_SERVICE"], service.hasPrefix("zztest-") else {
    FileHandle.standardError.write(Data("Refus : définir CLAUDE_SECRETS_SERVICE=zztest-…\n".utf8))
    exit(2)
}
let account = "vault"

func base() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
}

func read() -> (OSStatus, Data?) {
    var q = base()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let rc = SecItemCopyMatching(q as CFDictionary, &out)
    return (rc, out as? Data)
}

/// ACL qui fait confiance à ce binaire ET à /usr/bin/python3 (la CLI doit rester sans demande).
func makeAccess() -> SecAccess? {
    var me: SecTrustedApplication?, py: SecTrustedApplication?
    SecTrustedApplicationCreateFromPath(nil, &me)
    SecTrustedApplicationCreateFromPath(env["SPIKE_PYTHON"] ?? "/usr/bin/python3", &py)
    var acc: SecAccess?
    let apps: CFArray? = env["SPIKE_ACL"] == "any" ? nil : ([me, py].compactMap { $0 } as CFArray)
    guard SecAccessCreate("claude-secrets" as CFString, apps, &acc) == errSecSuccess else { return nil }
    return acc
}

func write(_ data: Data) -> OSStatus {
    let rc = SecItemUpdate(base() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if rc == errSecItemNotFound {
        var a = base(); a[kSecValueData as String] = data
        if let acc = makeAccess() { a[kSecAttrAccess as String] = acc }
        return SecItemAdd(a as CFDictionary, nil)
    }
    return rc
}

func ms(_ f: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds; f()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}

switch CommandLine.arguments.dropFirst().first ?? "" {
case "seed":   // 700 entrées fictives, valeurs multi-lignes et Unicode comprises
    var v: [String: [String: String]] = [:]
    for i in 0..<700 {
        v["ZZTEST_ENTRY_\(i)"] = ["value": "fictif-\(i)-é\n✓", "export": i % 7 == 0 ? "0" : "1",
                                  "source": i % 3 == 0 ? "bitwarden:Dossier" : "local"]
    }
    let d = try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
    print("write rc=\(write(d)) taille=\(d.count)")
case "read":
    var res: (OSStatus, Data?) = (0, nil)
    let t = ms { res = read() }
    var n = -1
    if let d = res.1, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { n = j.count }
    print("read rc=\(res.0) entrées=\(n) temps=\(String(format: "%.1f", t)) ms")
case "attrs":   // attributs seuls (date de modification), sans la valeur
    var q = base()
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    var rc: OSStatus = 0
    let t = ms { rc = SecItemCopyMatching(q as CFDictionary, &out) }
    let d = (out as? [String: Any])?[kSecAttrModificationDate as String] as? Date
    print("attrs rc=\(rc) mdat=\(d.map { "\($0)" } ?? "nil") temps=\(String(format: "%.1f", t)) ms")
case "delete":
    print("delete rc=\(SecItemDelete(base() as CFDictionary))")
default:
    print("usage : spike seed|read|delete")
}
