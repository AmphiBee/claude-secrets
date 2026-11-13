import Foundation
import SecretsCore

func runAwsTests() {
    print("AWS")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zztest-aws-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let creds = """
    # commentaire
    [default]
    aws_access_key_id = AKIAFICTIFDEFAULT
    aws_secret_access_key = secret-fictif-1

    [mon-profil.test]
    aws_access_key_id: AKIAFICTIFPROFIL
    aws_secret_access_key: secret-fictif-2
    aws_session_token = jeton-fictif

    [incomplet]
    aws_access_key_id = AKIAX
    """
    try! creds.write(to: tmp.appendingPathComponent("credentials"), atomically: true, encoding: .utf8)
    try! "[profile autre]\nregion = eu-west-3\n\n[default]\nregion = eu-west-1\ncredential_process = vieux\n".write(to: tmp.appendingPathComponent("config"), atomically: true, encoding: .utf8)

    let ps = Aws.profiles(in: tmp)
    check("profils lus (incomplet ignoré, jeton conservé)", ps.map(\.name) == ["default", "mon-profil.test"] && ps[1].sessionToken == "jeton-fictif" && ps[0].sessionToken == nil)
    check("nom de stockage comme aws_key", Aws.key("mon-profil.test", "access_key_id") == "AWS_MON_PROFIL_TEST_ACCESS_KEY_ID")

    let store = MemoryVaultStore([VaultSecret(name: "ZZTEST_X", value: "x")])
    let r1 = try? Aws.importProfiles(store: store, activate: false, dir: tmp, cli: "/bin/echo")
    let all = (try? store.load()) ?? []
    check("import : 2 profils, rien d'autre modifié", r1?.profiles.count == 2 && r1?.activated == false
          && FileManager.default.fileExists(atPath: tmp.appendingPathComponent("credentials").path))
    check("clés AWS hors environnement, jeton compris",
          all.filter { $0.name.hasPrefix("AWS_") }.count == 5 && all.filter { $0.name.hasPrefix("AWS_") }.allSatisfy { !$0.exported })
    let r2 = try? Aws.importProfiles(store: store, activate: true, dir: tmp, cli: "/bin/echo")
    let cfg = (try? String(contentsOf: tmp.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    check("activation : credentials écarté, sauvegardes faites", r2?.activated == true
          && !FileManager.default.fileExists(atPath: tmp.appendingPathComponent("credentials").path)
          && FileManager.default.fileExists(atPath: tmp.appendingPathComponent("credentials.disabled").path)
          && ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.contains(".bak-") }.count == 2)
    check("config : credential_process remplacé et ajouté, reste intact",
          cfg.contains("credential_process = /bin/echo aws-credentials default") && !cfg.contains("vieux")
          && cfg.contains("[profile mon-profil.test]\ncredential_process = /bin/echo aws-credentials mon-profil.test")
          && cfg.contains("region = eu-west-3") && cfg.contains("region = eu-west-1"))
    check("config en 0600", ((try? FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("config").path))?[.posixPermissions] as? Int) == 0o600)
    check("sans credentials : erreur claire", { do { _ = try Aws.importProfiles(store: store, activate: false, dir: tmp, cli: "/bin/echo"); return false } catch { return true } }())
}
