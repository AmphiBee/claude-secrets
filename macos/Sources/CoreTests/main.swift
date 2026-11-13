// Tests de SecretsCore : `swift run core-tests`. Aucun accès au trousseau, aucune valeur réelle.
import Foundation
import SecretsCore

nonisolated(unsafe) var failures = 0
func check(_ label: String, _ ok: Bool) {
    print("  [\(ok ? "✓" : "✗")] \(label)")
    if !ok { failures += 1 }
}

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

func json(_ name: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(name))) as! [String: Any]
}

// MARK: regroupement contre l'oracle Python
print("Regroupement (oracle Python)")
for name in ["synthetic", "synthetic-nodomains", "bwtests"] {
    let d = json("\(name).json")
    let items = (d["items"] as! [[String: Any]]).map {
        (name: $0["name"] as! String, value: $0["value"] as! String, exported: $0["exported"] as! Bool)
    }
    let domains = d["domains"] as! [String: String], overrides = d["overrides"] as! [String: String]
    let exp = d["expected"] as! [String: Any]

    let entries = grouped(items)
    let gotEntries = entries.map { "\($0.kind.rawValue)|\($0.base)|\($0.user ?? "∅")|\($0.exported)" }
    let wantEntries = (exp["entries"] as! [[Any]]).map {
        "\($0[0])|\($0[1])|\(($0[2] as? String) ?? "∅")|\(($0[3] as! Bool))"
    }
    check("\(name) : entrées logiques identiques (\(entries.count))", gotEntries == wantEntries)

    let tax = Taxonomy(entries, domains: domains, overrides: overrides)
    let groups = tax.group(entries)
    let want = exp["groups"] as! [[String: Any]]
    check("\(name) : même nombre de groupes (\(groups.count))", groups.count == want.count)
    var bad: [String] = []
    for (g, w) in zip(groups, want) {
        let same = g.id == (w["id"] as! String) && g.label == (w["label"] as! String)
            && g.kind.rawValue == (w["kind"] as! String) && g.manual == (w["manual"] as! Bool)
            && g.members.map(\.base) == (w["members"] as! [String])
        if !same { bad.append("\(g.id)≠\(w["id"]!)") }
    }
    check("\(name) : id, libellé, type, manuel, membres identiques" + (bad.isEmpty ? "" : " — \(bad.prefix(5))"), bad.isEmpty)
    let labels = exp["labels"] as! [String: String]
    check("\(name) : libellé de chaque entrée", entries.allSatisfy { tax.labelOf($0.base) == labels[$0.base] })
    let tones = exp["tones"] as! [String: Int]
    check("\(name) : teinte de chaque groupe", groups.allSatisfy { toneIndex($0.label) == tones[$0.label] })
}

print("Teintes")
let tones = json("tones.json") as! [String: Int]
check("teintes accents, espaces, ß, vide", tones.allSatisfy { toneIndex($0.key) == $0.value })
check("crc32 « 123456789 » = CBF43926", crc32(Array("123456789".utf8)) == 0xCBF43926)

print("Python title()")
check("title", pyTitle("mondial relay") == "Mondial Relay" && pyTitle("a1b") == "A1B" && pyTitle("été-soleil") == "Été-Soleil")

// MARK: format du coffre
print("Format du coffre")
let multi = "ligne1\nligne2 é ✓ \"guillemets\" \\ /"
let secrets = [
    VaultSecret(name: "ZZTEST_B", value: multi, exported: false, source: "bitwarden:Dossier"),
    VaultSecret(name: "ZZTEST_A", value: "x"),
    VaultSecret(name: "_BW_SESSION", value: "reserve"),
]
let data = try! Vault.encode(secrets)
let text = String(decoding: data, as: UTF8.self)
check("noms réservés conservés à l'écriture (_BW_SESSION)", (try! Vault.decode(data, includeReserved: true)).count == 3)
check("« / » non échappé", !text.contains("\\/"))
let back = try! Vault.decode(data)
check("noms réservés écartés", back.map(\.name) == ["ZZTEST_A", "ZZTEST_B"])
check("valeur multi-ligne et Unicode relue à l'identique", back.last?.value == multi)
check("export et source conservés", back.last?.exported == false && back.last?.source == "bitwarden:Dossier")
check("export absent = exporté, source absente = local",
      try! Vault.decode(Data(#"{"ZZTEST_X":{"value":"v"}}"#.utf8)).first.map { $0.exported && $0.source == "local" } == true)
check("coffre illisible → erreur sans valeur", (try? Vault.decode(Data("pas du json".utf8))) == nil)
check("description d'un secret ne contient pas la valeur", !"\(secrets[0])".contains("ligne1") && !"\(secrets[0].debugDescription)".contains("ligne1"))
check("noms valides", Vault.isValidName("ZZTEST_A1") && !Vault.isValidName("zz") && !Vault.isValidName("_X") && !Vault.isValidName("1A"))

print(failures == 0 ? "\nTout est vert." : "\n\(failures) échec(s).")
exit(failures == 0 ? 0 : 1)
