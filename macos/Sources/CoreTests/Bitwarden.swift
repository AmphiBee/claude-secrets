// Tests Bitwarden : oracle Python pour la traduction, faux `bw` (tests/fake-bw) pour la synchronisation.
// Hors ligne, sans compte, sans trousseau (coffre en mémoire) et sans toucher au vrai state.json.
import Foundation
import SecretsCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

func runBitwardenTests(_ fixtures: URL) {
    // MARK: traduction
    print("Bitwarden : traduction (oracle Python)")
    let d = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("bw.json"))) as! [String: Any]
    let items = (d["items"] as! [[String: Any]]).map(BwItem.init)
    let want = (d["map"] as! [[Any]]).map { "\($0[0])|\($0[1])|\($0[2] as! Bool)" }
    let got = BitwardenClient.map(items).map { "\($0.name)|\($0.value)|\($0.exported)" }
    check("bw_map identique (\(want.count) secrets)" + (got == want ? "" : " — \(got) ≠ \(want)"), got == want)
    check("bw_domains identique", BitwardenClient.domains(items) == (d["domains"] as! [String: String]))
    let slugs = d["slugs"] as! [String: String]
    check("bw_slug identique", slugs.allSatisfy { BitwardenClient.slug($0.key) == $0.value })

    // MARK: client contre le faux bw
    print("Bitwarden : connexion et synchronisation (faux bw)")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zztest-bw-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let vaultFile = tmp.appendingPathComponent("vault.json")
    try! FileManager.default.copyItem(at: root.appendingPathComponent("tests/vault.json"), to: vaultFile)
    setenv("FAKE_BW_STATE", tmp.appendingPathComponent("state.json").path, 1)
    setenv("FAKE_BW_VAULT", vaultFile.path, 1)
    unsetenv("FAKE_BW_MIGRATOR"); unsetenv("FAKE_BW_MIGRATOR_UNLOCK")
    AppState.url = tmp.appendingPathComponent("app-state.json")

    let store = MemoryVaultStore([VaultSecret(name: "ZZTEST_LOCAL", value: "a-moi"),
                                  VaultSecret(name: "ZZTEST_AUTRE", value: "x", source: "bitwarden:Autre")])
    let bw = BitwardenClient(store: store, executable: root.appendingPathComponent("tests/fake-bw").path)
    let secret = "mauvais-mdp-fictif"

    check("avant connexion : unauthenticated", (try? bw.status()) == "unauthenticated")
    check("synchroniser sans compte : erreur claire", { do { _ = try bw.sync(); return false } catch { return "\(error)".contains("Aucun compte") } }())
    check("serveur configuré (https ajouté)", (try? bw.setServer("vault.exemple.fr/")) == "https://vault.exemple.fr")
    do { _ = try bw.login(email: "x@exemple.fr", password: secret); check("mauvais mot de passe refusé", false) }
    catch { check("mauvais mot de passe refusé, sans l'écho du mot de passe", !"\(error)".contains(secret)) }
    let session = try? bw.login(email: "x@exemple.fr", password: "bonmotdepasse")
    check("connexion : session reçue", session == "SESSION-XYZ")
    check("e-mail mémorisé dans la config", BitwardenClient.conf()["email"] as? String == "x@exemple.fr")
    check("changer de serveur connecté : refusé", { do { _ = try bw.setServer("autre.exemple.fr"); return false } catch { return true } }())

    check("coffre verrouillé, pas de mot de passe : BwLocked", { do { _ = try bw.sync(); return false } catch { return error is BwLocked } }())
    check("session oubliée = rien dans le coffre", (try? store.load(includeReserved: true))?.contains { $0.name == bwSessionKey } == false)
    BitwardenClient.setConf(["folder": "Claude Secrets"])
    var rep = SyncReport()
    do { rep = try bw.sync(password: "bonmotdepasse") } catch { check("synchronisation : \(error)", false) }
    check("première synchro : secrets ajoutés (\(rep.added.count))", rep.added.count >= 4 && rep.updated.isEmpty && rep.removed.isEmpty)
    let all = (try? store.load()) ?? []
    check("origine = bitwarden:<dossier>", all.filter { rep.added.contains($0.name) }.allSatisfy { $0.source == "bitwarden:Claude Secrets" })
    check("session conservée dans le coffre, invisible et hors environnement",
          (try? store.load(includeReserved: true))?.first { $0.name == bwSessionKey }.map { $0.value == "SESSION-XYZ" && !$0.exported } == true
          && !all.contains { $0.name == bwSessionKey })
    check("secrets locaux et d'un autre dossier intacts", all.contains { $0.name == "ZZTEST_LOCAL" } && all.contains { $0.name == "ZZTEST_AUTRE" })
    check("adresses web enregistrées dans state.json", !((AppState.read()["domains"] as? [String: String]) ?? [:]).isEmpty && rep.domainsChanged)
    let again = try? bw.sync()
    check("deuxième synchro, session réutilisée sans mot de passe : rien à changer", again.map { !$0.changed && !$0.domainsChanged } == true)

    // un secret modifié côté Bitwarden, un autre retiré du dossier
    var vault = try! JSONSerialization.jsonObject(with: Data(contentsOf: vaultFile)) as! [String: Any]
    var its = vault["items"] as! [[String: Any]]
    var changedName = ""
    if let i = its.firstIndex(where: { ($0["folderId"] as? String) == "f1" }) {
        var it = its[i]; var login = it["login"] as! [String: Any]; login["password"] = "nouveau-fictif"; it["login"] = login; its[i] = it
        changedName = it["name"] as! String
    }
    let removedItem = its.removeLast { ($0["folderId"] as? String) == "f1" }
    vault["items"] = its
    try! JSONSerialization.data(withJSONObject: vault).write(to: vaultFile)
    let r2 = try? bw.sync()
    check("valeur modifiée côté Bitwarden : mise à jour (\(changedName))", (r2?.updated.count ?? 0) >= 1 && r2?.removed.isEmpty == true)
    let r3 = try? bw.sync(prune: true)
    check("--prune retire ce qui a disparu du dossier", (r3?.removed.count ?? 0) >= 1 && removedItem != nil)
    let after = (try? store.load()) ?? []
    check("--prune épargne le local et les autres dossiers", after.contains { $0.name == "ZZTEST_LOCAL" } && after.contains { $0.name == "ZZTEST_AUTRE" })
    check("dossier vide + prune : refusé, rien supprimé", { do { _ = try bw.sync(prune: true, folder: "Vide"); return false } catch { return "\(error)".contains("vide") } }())
    check("dossier inconnu : message clair", { do { _ = try bw.sync(folder: "Inexistant"); return false } catch { return "\(error)".contains("n'existe pas") } }())

    // serveurs plus anciens que le CLI
    try? bw.forgetSession(); _ = try? bw.run(["lock"])
    setenv("FAKE_BW_MIGRATOR_UNLOCK", "1", 1)
    check("unlock : migration en échec mais session récupérée", (try? bw.unlock(password: "bonmotdepasse")) == "SESSION-XYZ")
    unsetenv("FAKE_BW_MIGRATOR_UNLOCK")
    _ = try? bw.run(["logout"])
    setenv("FAKE_BW_MIGRATOR", "1", 1)
    let l = try? bw.login(email: "x@exemple.fr", password: "bonmotdepasse")
    check("login : migration en échec, compte pourtant connecté → nil", l == .some(nil))
    unsetenv("FAKE_BW_MIGRATOR")
    check("déconnexion : session oubliée, e-mail effacé", {
        try? bw.saveSession("S"); try? bw.logout()
        return (try? store.load(includeReserved: true))?.contains { $0.name == bwSessionKey } == false
            && (BitwardenClient.conf()["email"] is NSNull || BitwardenClient.conf()["email"] == nil)
    }())
}

private extension Array {
    mutating func removeLast(where p: (Element) -> Bool) -> Element? {
        guard let i = lastIndex(where: p) else { return nil }
        return remove(at: i)
    }
}
