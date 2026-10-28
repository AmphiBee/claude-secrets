#!/usr/bin/python3
"""Tests de Claude Secrets.

    tests/run.py            tout
    tests/run.py core       logique et stockage
    tests/run.py bitwarden  synchronisation (faux CLI, ni réseau ni compte)
    tests/run.py gui        interface GTK (nécessite une session graphique)

Les secrets créés sont préfixés ZZTEST_ et supprimés à la fin. L'application de
l'utilisateur n'est pas perturbée : les tests utilisent un autre identifiant
d'application.
"""
import importlib.machinery as M
import importlib.util as U
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
PREFIX = "ZZTEST_"
RESULTS = []
AKENEO_TONE = 14   # figé : crc32 est stable, hash() ne l'est pas d'un lancement à l'autre


def check(label, condition):
    RESULTS.append((label, bool(condition)))
    print(f"  [{'✓' if condition else '✗'}] {label}", flush=True)


def load_app():
    loader = M.SourceFileLoader("cs", str(ROOT / "claude-secrets"))
    mod = U.module_from_spec(U.spec_from_loader("cs", loader))
    loader.exec_module(mod)
    return mod


def cleanup(cs):
    for name, *_ in cs.store_meta(include_reserved=True):
        if name.startswith(PREFIX) or name == cs.BW_SESSION_KEY:
            cs.store_del(name)
    cs.refresh_cache()


def fake_bw_env(tmp, migrator=False):
    os.environ["PATH"] = f"{TESTS}:" + os.environ["PATH"]
    os.environ["FAKE_BW_STATE"] = str(tmp / "bwstate.json")
    os.environ["FAKE_BW_VAULT"] = str(tmp / "vault.json")
    shutil.copy(TESTS / "vault.json", tmp / "vault.json")
    shutil.copy(TESTS / "fake-bw", tmp / "bw")
    (tmp / "bw").chmod(0o755)
    os.environ["PATH"] = f"{tmp}:" + os.environ["PATH"]
    if migrator:
        os.environ["FAKE_BW_MIGRATOR"] = "1"
    else:
        os.environ.pop("FAKE_BW_MIGRATOR", None)


# ───────────────────────────── logique et stockage ────────────────────────────

def test_core(cs):
    print("\nLogique et stockage")
    cs.store_set(PREFIX + "SIMPLE", "v1")
    cs.store_set(PREFIX + "PRIVE", "v2", export=False)
    cs.save_pair(PREFIX + "PAIRE", "u@x.fr", "mdp")
    cs.store_set("_" + PREFIX + "RESERVE", "interne", export=False)
    cs.refresh_cache()

    names = {n for n, _, _ in cs.store_all()}
    check("secret simple enregistré", PREFIX + "SIMPLE" in names)
    check("paire enregistrée en deux variables",
          {PREFIX + "PAIRE_USER", PREFIX + "PAIRE_PASSWORD"} <= names)
    check("nom réservé masqué", "_" + PREFIX + "RESERVE" not in names)

    meta = {n: (v, e, s) for n, v, e, s in cs.store_meta()}
    check("valeur relue à l'identique", meta[PREFIX + "SIMPLE"][0] == "v1")
    check("secret hors environnement marqué", meta[PREFIX + "PRIVE"][1] is False)

    cache = pathlib.Path(cs.CACHE).read_text()
    check("secret exporté présent dans le cache shell",
          f"export {PREFIX}SIMPLE=" in cache)
    check("secret hors environnement absent du cache",
          f"{PREFIX}PRIVE=" not in cache)

    entries = {(k, b) for k, b, *_ in cs.grouped(cs.store_all())}
    check("regroupement de la paire", ("pair", PREFIX + "PAIRE") in entries)
    check("pas de doublon après réécriture",
          (cs.store_set(PREFIX + "SIMPLE", "v3"),
           len([n for n, *_ in cs.store_meta() if n == PREFIX + "SIMPLE"]) == 1)[1])

    cs.delete_entry("pair", PREFIX + "PAIRE")
    names = {n for n, _, _ in cs.store_all()}
    check("suppression d'une paire : les deux variables partent",
          not {PREFIX + "PAIRE_USER", PREFIX + "PAIRE_PASSWORD"} & names)

    check("nom de profil AWS lisible",
          cs.aws_profile_label("AWS_AMPHIBEE") == "amphibee")

    # classement automatique par service, d'après les noms
    names = ["APP_HUBSPOT_COM", "LOGIN_HUBSPOT_COM",
             "MEO_FR", "PMA_MEO_DOCKER", "MEO_PREPROD_AMPHIBEE_FR",
             "BUNNY_API_KEY", "OPENAI_API_KEY", "X_API_KEY",
             "MAILGUN_COM", "CANVA_COM",
             "PASSERELLE_ALPHA_COM", "PASSERELLE_OMEGA_COM",
             "PASSERELLE_GAMMA_COM", "PASSERELLE_DELTA_COM",
             "GANDI_NET", "ID_GANDI_NET", "ADMIN_GANDI_NET"]
    ents = [("pair", n, "u", "p", True) for n in names] \
        + [("aws", "AWS_UNIQUE", "AKIA0000", "s", False)]
    tax = cs.Taxonomy(ents)
    groups = {g["label"]: g for g in tax.group(ents)}
    members = lambda lab: [e[1] for e in groups[lab]["members"]]
    check("APP_/LOGIN_ et l'extension sont écartés → un seul service",
          members("Hubspot") == ["APP_HUBSPOT_COM", "LOGIN_HUBSPOT_COM"])
    check("ID_/ADMIN_ et l'extension sont écartés → un seul service",
          len(members("Gandi")) == 3)
    check("préfixe d'outil et environnement → le projet",
          members("Meo") == ["MEO_FR", "MEO_PREPROD_AMPHIBEE_FR", "PMA_MEO_DOCKER"])
    check("un environnement dans le nom marque un projet",
          groups["Meo"]["kind"] == "project" and groups["Hubspot"]["kind"] == "service")
    check("« API » (mot de variable) n'est jamais un service", "Api" not in groups)
    check("préfixe générique inconnu appris sur les données",
          "Passerelle" not in groups)
    check("une entrée isolée avec domaine → « Autres sites »",
          {"MAILGUN_COM", "CANVA_COM"} <= set(members("Autres sites")))
    check("une entrée isolée sans domaine → « Autres clés et accès »",
          {"BUNNY_API_KEY", "OPENAI_API_KEY", "X_API_KEY"}
          <= set(members("Autres clés et accès")))
    check("un profil AWS reste dans le groupe AWS, jamais un projet",
          "AWS_UNIQUE" in members("Aws") and groups["Aws"]["kind"] == "service")
    check("aucun service ne compte un seul membre",
          all(len(g["members"]) >= 2 for g in groups.values()
              if g["kind"] in ("service", "project") and g["label"] != "Aws"))

    # classement par adresse web (Bitwarden)
    host = lambda uri: cs.bw_host({"login": {"uris": [{"uri": uri}]}})
    check("hôte d'une adresse complète", host("https://app.hubspot.com/login") == "app.hubspot.com")
    check("hôte d'une adresse sans schéma, sans www",
          host("www.exemple.fr/espace") == "exemple.fr")
    check("application mobile, localhost et IP ignorés",
          not any(host(u) for u in ("androidapp://com.x", "http://localhost:3000",
                                    "http://192.168.1.2:8080", "http://site.local")))
    check("domaine de l'hôte", cs.registrable("app.hubspot.com") == "hubspot.com")
    check("suffixe à deux niveaux", cs.registrable("a.b.foo.co.uk") == "foo.co.uk"
          and cs.registrable("www.impots.gouv.fr") == "impots.gouv.fr")

    ents = [("pair", n, "u", "p", True) for n in
            ["MON_CRM", "HUBSPOT_ADMIN", "DOCS", "DRIVE", "SHEETS", "MAILS",
             "PREPROD_ECRANLARGE_AMPHIBEE_FR", "BETA_ECRANLARGE_COM",
             "WP_AMPHIBEE_FR", "GIT_AMPHIBEE_FR", "SEUL_SANS_ADRESSE"]]
    doms = {"MON_CRM": "app.hubspot.com", "DOCS": "docs.google.com",
            "DRIVE": "drive.google.com", "SHEETS": "sheets.google.com",
            "MAILS": "mail.google.com",
            "PREPROD_ECRANLARGE_AMPHIBEE_FR": "preprod.ecranlarge.amphibee.fr",
            "BETA_ECRANLARGE_COM": "beta.ecranlarge.com",
            "WP_AMPHIBEE_FR": "wp.amphibee.fr", "GIT_AMPHIBEE_FR": "git.amphibee.fr"}
    tax = cs.Taxonomy(ents, doms)
    groups = {g["label"]: [e[1] for e in g["members"]] for g in tax.group(ents)}
    check("l'adresse web prime sur un nom sans rapport",
          "MON_CRM" in groups.get("Hubspot", []))
    check("un nom qui cite le service rejoint le groupe de l'adresse",
          "HUBSPOT_ADMIN" in groups.get("Hubspot", []))
    check("des sous-domaines d'un même service ne l'éclatent pas",
          len(groups.get("Google", [])) == 4)
    check("un projet hébergé garde son groupe",
          set(groups.get("Ecranlarge", [])) == {"PREPROD_ECRANLARGE_AMPHIBEE_FR",
                                                "BETA_ECRANLARGE_COM"})
    check("l'hébergeur garde ses propres sites",
          set(groups.get("Amphibee", [])) == {"WP_AMPHIBEE_FR", "GIT_AMPHIBEE_FR"})
    check("un environnement dans l'adresse marque un projet",
          next(g for g in tax.group(ents) if g["label"] == "Ecranlarge")["kind"]
          == "project")
    check("sans adresse ni voisin → « Autres clés et accès »",
          "SEUL_SANS_ADRESSE" in groups.get("Autres clés et accès", []))

    # groupe choisi à la main
    ents = [("pair", n, "u", "p", True) for n in
            ["MAILGUN_COM", "CANVA_COM", "GANDI_NET", "ID_GANDI_NET", "SOLO_X", "SOLO2_Y"]]
    auto = cs.Taxonomy(ents)
    mine = cs.Taxonomy(ents, None, {"MAILGUN_COM": "Mes outils", "CANVA_COM": "Mes outils",
                                    "SOLO_X": "Perso", "SOLO2_Y": "Gandi",
                                    "ID_GANDI_NET": "Autre"})
    g = {x["label"]: x for x in mine.group(ents)}
    names = lambda lab: [e[1] for e in g[lab]["members"]]
    check("un choix manuel regroupe des entrées sans rapport",
          names("Mes outils") == ["CANVA_COM", "MAILGUN_COM"] and g["Mes outils"]["manual"])
    check("un groupe choisi peut ne contenir qu'une entrée", names("Perso") == ["SOLO_X"])
    check("un nom de groupe existant fusionne avec lui", "SOLO2_Y" in names("Gandi"))
    check("le choix manuel prime sur le classement automatique",
          "ID_GANDI_NET" in names("Autre")
          and any(e[1] == "ID_GANDI_NET" for e in auto.group(ents)[0]["members"]))
    check("un groupe mêlant auto et manuel n'est pas dit « manuel »",
          g["Gandi"]["manual"] is False)
    check("le nom du groupe d'une entrée", mine.label_of("MAILGUN_COM") == "Mes outils")
    check("sans choix, retour au classement automatique",
          auto.label_of("MAILGUN_COM") == "")

    # identité visuelle : les jetons de couleur gardent un contraste AA (≥ 4,5)
    def luminance(h):
        c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

    def contrast(a, b):
        hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
        return (hi + 0.05) / (lo + 0.05)

    for name, css in (("clair", cs.TOKENS_LIGHT), ("sombre", cs.TOKENS_DARK)):
        t = dict(re.findall(r"@define-color (\w+) (#[0-9A-Fa-f]{6});", css))
        pairs = [("ink", "paper"), ("ink", "surface"), ("muted", "paper"),
                 ("muted", "surface"), ("copper_ink", "paper"),
                 ("copper_ink", "surface"), ("on_copper", "copper")]
        check(f"thème {name} : contraste AA sur tous les couples de couleurs",
              all(contrast(t[a], t[b]) >= 4.5 for a, b in pairs))

    # teinte des monogrammes : pastel clair, lettre foncée, bordure intermédiaire
    check("la teinte d'un service est stable d'un lancement à l'autre",
          cs.tone_index("Akeneo") == AKENEO_TONE)
    check("« Mondial Relay », MONDIALRELAY et Mondial-Relay ont la même teinte",
          len({cs.tone_index(x) for x in ("Mondial Relay", "MONDIALRELAY",
                                          "Mondial-Relay", "mondial_relay")}) == 1)
    check("les accents ne changent pas la teinte",
          cs.tone_index("Électricité") == cs.tone_index("Electricite"))
    services = ["Adexos", "Akeneo", "Alveo", "Amazon", "Amphi", "Amphibee", "Aws",
                "Beemine", "Beewatch", "Cloudflare", "Docusign", "Ecranlarge",
                "Gandi", "Github", "Google", "Hubspot", "Icea", "Kokomo", "Meo",
                "Natureo", "Ovh", "Piano", "Stripe", "Zztest"]
    check("les teintes se répartissent (pas de collisions en série)",
          len({cs.tone_index(x) for x in services}) >= 14)
    tones = [cs.tone_colors(i) for i in range(cs.TONES)]
    check("chaque teinte : contraste AA lettre sur fond",
          all(contrast(fg, bg) >= 4.5 for bg, _b, fg in tones))
    check("chaque teinte : fond plus clair que la bordure, plus claire que la lettre",
          all(luminance(bg) > luminance(b) > luminance(fg) for bg, b, fg in tones))

    # mode d'installation : script, paquet système ou AppImage
    saved_env = os.environ.pop("APPIMAGE", None)
    try:
        check("un script du dépôt est un mode « user »",
              cs.install_kind(pathlib.Path("/home/x/depot/claude-secrets")) == "user")
        check("~/.local/bin est un mode « user »",
              cs.install_kind(cs.HOME / ".local/bin/claude-secrets") == "user")
        check("/usr/bin est un mode « system » (paquet)",
              cs.install_kind(pathlib.Path("/usr/bin/claude-secrets")) == "system")
        check("/usr/local/bin est aussi « system »",
              cs.install_kind(pathlib.Path("/usr/local/bin/claude-secrets")) == "system")
        check("un paquet garde sa commande là où il l'a mise",
              cs.bin_path("system", pathlib.Path("/usr/bin/claude-secrets"))
              == pathlib.Path("/usr/bin/claude-secrets"))
        check("un script est copié dans ~/.local/bin",
              cs.bin_path("user") == cs.HOME / ".local/bin/claude-secrets")
        os.environ["APPIMAGE"] = "/tmp/Claude_Secrets.AppImage"
        check("sous un AppImage, on le détecte (même si __file__ est dans /tmp/.mount_)",
              cs.install_kind(pathlib.Path("/tmp/.mount_abc/usr/bin/claude-secrets"))
              == "appimage")
        check("un AppImage est copié dans ~/.local/bin, jamais son script interne",
              cs.bin_path(None, pathlib.Path("/tmp/.mount_abc/usr/bin/claude-secrets"))
              == cs.HOME / ".local/bin/claude-secrets")
        os.environ.pop("APPIMAGE")
        check("~ remplace le dossier personnel", cs.tilde(cs.HOME / ".config/x") == "~/.config/x"
              and cs.tilde("/usr/bin/x") == "/usr/bin/x")
        # un paquet fournit lanceur et icône : detect() les cherche dans /usr
        real = (cs.install_kind, cs.SYSTEM_DESKTOP, cs.SYSTEM_ICON)
        tmp_pkg = pathlib.Path(tempfile.mkdtemp(prefix="cs-pkg-"))
        try:
            cs.install_kind = lambda here=None: "system"
            cs.SYSTEM_DESKTOP, cs.SYSTEM_ICON = tmp_pkg / "a.desktop", tmp_pkg / "a.svg"
            check("paquet sans lanceur ni icône : configuration incomplète",
                  not cs.detect()["desktop"] and not cs.detect()["icon"])
            cs.SYSTEM_DESKTOP.write_text("x")
            cs.SYSTEM_ICON.write_text("x")
            check("paquet : le lanceur et l'icône du système comptent",
                  cs.detect()["desktop"] and cs.detect()["icon"])
        finally:
            cs.install_kind, cs.SYSTEM_DESKTOP, cs.SYSTEM_ICON = real
            shutil.rmtree(tmp_pkg, ignore_errors=True)
    finally:
        if saved_env is not None:
            os.environ["APPIMAGE"] = saved_env

    # sous AppImage, les programmes de l'hôte retrouvent leur environnement
    img = {"APPIMAGE": "/x.AppImage", "APPDIR": "/tmp/.mount_x", "PYTHONHOME": "/tmp/.mount_x/usr",
           "LD_LIBRARY_PATH": "/tmp/.mount_x/usr/lib", "CS_HOST_LD_LIBRARY_PATH": "/opt/lib",
           "XDG_DATA_DIRS": "/tmp/.mount_x/usr/share:/usr/share",
           "CS_HOST_XDG_DATA_DIRS": "/usr/share", "HOME": "/h"}
    out = cs.host_env(img)
    check("l'AppImage rend à l'hôte son LD_LIBRARY_PATH d'origine",
          out["LD_LIBRARY_PATH"] == "/opt/lib" and out["XDG_DATA_DIRS"] == "/usr/share")
    check("les variables de l'image qui n'existaient pas sont retirées",
          "PYTHONHOME" not in out and "APPDIR" not in out and out["HOME"] == "/h")
    check("hors AppImage, l'environnement est laissé tel quel",
          cs.host_env({"LD_LIBRARY_PATH": "/a", "HOME": "/h"}) == {"LD_LIBRARY_PATH": "/a", "HOME": "/h"})

    # le cache du shell est relu au lancement pour afficher la liste tout de suite
    real_cache = cs.CACHE
    cs.CACHE = pathlib.Path(tempfile.mkdtemp(prefix="cs-cache-")) / "c.env"
    try:
        sample = [(PREFIX + "A", "simple", True),
                  (PREFIX + "B", "espace 'quote' \"guillemets\" $x `y`", True),
                  (PREFIX + "C", "ligne1\nligne2", True),
                  (PREFIX + "D", "hors environnement", False)]
        cs.write_cache(sample)
        got = cs.read_cache()
        check("le cache se relit à l'identique (guillemets, retours à la ligne)",
              got == [x for x in sample if x[2]])
        check("un secret hors environnement n'est pas dans le cache",
              PREFIX + "D" not in {n for n, _, _ in got})
        cs.CACHE.chmod(0o644)
        check("un cache lisible par d'autres est refusé", cs.read_cache() == [])
        cs.CACHE.chmod(0o600)
        cs.CACHE.write_text("export A=1\nrm -rf /\n")
        check("un cache altéré est refusé", cs.read_cache() == [])
        cs.CACHE.write_text("")
        check("un cache vide ne donne rien", cs.read_cache() == [])
    finally:
        shutil.rmtree(cs.CACHE.parent, ignore_errors=True)
        cs.CACHE = real_cache

    # une installation ne doit pas effacer le reste de l'état local
    saved = cs.STATE.read_text() if cs.STATE.exists() else None
    try:
        cs.state_update(bitwarden={"folder": "ZZTEST", "email": "o@x.fr"})
        cs.state_update(installed=True, version=1)
        check("l'installation préserve la configuration Bitwarden",
              cs.bw_conf().get("folder") == "ZZTEST")
    finally:
        if saved is not None:
            cs.STATE.write_text(saved)
        elif cs.STATE.exists():
            cs.STATE.unlink()


# ───────────────────────────── synchronisation ───────────────────────────────

def test_bitwarden(cs, tmp):
    print("\nSynchronisation Bitwarden")
    # Ne jamais toucher à la configuration réelle de l'utilisateur.
    saved = cs.STATE.read_text() if cs.STATE.exists() else None
    try:
        _test_bitwarden(cs, tmp)
    finally:
        if saved is not None:
            cs.STATE.write_text(saved)


def _test_bitwarden(cs, tmp):
    fake_bw_env(tmp)
    pathlib.Path(os.environ["FAKE_BW_STATE"]).unlink(missing_ok=True)

    try:
        cs.bw_sync(folder="Claude Secrets")
        check("non connecté → erreur explicite", False)
    except cs.BwError as e:
        check("non connecté → erreur explicite", "bw-setup" in str(e))

    check("URL sans schéma corrigée",
          cs.bw_set_server("vault.exemple.fr") == "https://vault.exemple.fr")
    check("cloud par défaut",
          cs.bw_set_server("") == "https://vault.bitwarden.com")
    cs.bw_set_server("vault.exemple.fr")

    try:
        cs.bw_login("o@exemple.fr", "mauvais")
        check("mot de passe refusé", False)
    except cs.BwError:
        check("mot de passe refusé", True)

    session = cs.bw_login("o@exemple.fr", "bonmotdepasse")
    cs.store_set(cs.BW_SESSION_KEY, session, export=False)
    reads = []
    real_meta = cs.store_meta
    cs.store_meta = lambda *a, **k: (reads.append(1), real_meta(*a, **k))[1]
    report = cs.bw_sync(folder="Claude Secrets")
    cs.store_meta = real_meta
    check("une synchro ne lit le trousseau qu'une fois", len(reads) == 1)
    check("le rapport porte l'état final du trousseau",
          PREFIX + "CLOUDFLARE" in {n for n, _, _ in report["items"]})
    check("le cache du shell suit la synchro",
          f"export {PREFIX}CLOUDFLARE=" in cs.CACHE.read_text())

    names = {n for n, _, _ in cs.store_all()}
    check("élément simple importé", PREFIX + "CLOUDFLARE" in names)
    check("identifiant + mot de passe importés",
          {PREFIX + "CLIENT_USER", PREFIX + "CLIENT_PASSWORD"} <= names)
    check("nom forcé par claude_secrets_name", PREFIX + "RENOMME_USER" in names)
    check("champ masqué importé", PREFIX + "STRIPE_WEBHOOK" in names)
    check("champ visible ignoré", PREFIX + "STRIPE_VISIBLE" not in names)
    check("autre dossier ignoré", PREFIX + "HORS_DOSSIER" not in names)

    meta = {n: (v, e, s) for n, v, e, s in cs.store_meta()}
    check("claude_secrets_export respecté", meta[PREFIX + "INTERNE"][1] is False)
    check("origine enregistrée avec le dossier",
          meta[PREFIX + "CLOUDFLARE"][2] == "bitwarden:Claude Secrets")
    check("clé de session masquée", cs.BW_SESSION_KEY not in names)

    doms = cs.state_get("domains", {})
    check("la synchro retient l'adresse des éléments",
          doms.get(PREFIX + "CLOUDFLARE") == "dash.cloudflare.com")
    check("l'adresse vaut pour l'entrée groupée et ses deux variables",
          doms.get(PREFIX + "CLIENT") == "client.exemple.fr"
          and doms.get(PREFIX + "CLIENT_USER") == "client.exemple.fr")
    check("une adresse locale n'est pas retenue", PREFIX + "STRIPE_WEBHOOK" not in doms)
    check("la synchro signale un changement d'adresses",
          report["domains_changed"] is True)
    check("2e passage : adresses inchangées",
          cs.bw_sync(folder="Claude Secrets")["domains_changed"] is False)
    check("2e passage sans changement",
          not any(cs.bw_sync(folder="Claude Secrets")[k]
                  for k in ("added", "updated", "removed")))

    vault = json.loads(pathlib.Path(os.environ["FAKE_BW_VAULT"]).read_text())
    vault["items"] = [i for i in vault["items"] if i["id"] != "i1"]
    pathlib.Path(os.environ["FAKE_BW_VAULT"]).write_text(json.dumps(vault))
    # garde-fou : un secret venu d'un AUTRE dossier ne doit jamais être purgé
    cs.store_set(PREFIX + "AUTRE_DOSSIER", "v", source="bitwarden:Perso")
    check("sans --prune, rien n'est supprimé",
          PREFIX + "CLOUDFLARE" in {n for n, _, _ in cs.store_all()})
    check("avec --prune, l'élément retiré du coffre disparaît",
          cs.bw_sync(prune=True, folder="Claude Secrets")["removed"] == [PREFIX + "CLOUDFLARE"])

    check("l'adresse d'un secret supprimé n'est plus conservée",
          PREFIX + "CLOUDFLARE" not in cs.state_get("domains", {}))
    check("--prune épargne les secrets d'un autre dossier",
          PREFIX + "AUTRE_DOSSIER" in {n for n, _, _ in cs.store_all()})
    try:
        cs.bw_sync(prune=True, folder="Vide")
        check("--prune refuse un dossier vide", False)
    except cs.BwError as e:
        check("--prune refuse un dossier vide", "vide" in str(e))

    cs.bw_run(["lock"])
    try:
        cs.bw_sync(folder="Claude Secrets")
        check("coffre verrouillé → mot de passe redemandé", False)
    except cs.BwLocked:
        check("coffre verrouillé → mot de passe redemandé", True)
    cs.bw_sync(password="bonmotdepasse", folder="Claude Secrets")
    check("session mémorisée réutilisée",
          cs.bw_sync(folder="Claude Secrets")["total"] > 0)

    try:
        cs.bw_set_server("https://autre.exemple.fr")
        check("changer de serveur connecté → refus clair", False)
    except cs.BwError as e:
        check("changer de serveur connecté → refus clair", "bw-logout" in str(e))

    # serveur auto-hébergé plus ancien que le CLI
    cs.store_del(cs.BW_SESSION_KEY)
    cs.bw_run(["logout"])
    fake_bw_env(tmp, migrator=True)
    cs.bw_set_server("vault.exemple.fr")
    check("connexion « en échec » mais compte connecté → pas d'exception",
          cs.bw_login("o@exemple.fr", "bonmotdepasse") is None)

    # même défaut au déverrouillage : la session est ouverte, la clé est
    # écrite, puis la migration échoue
    os.environ["FAKE_BW_MIGRATOR_UNLOCK"] = "1"
    try:
        session = cs.bw_unlock("bonmotdepasse")
        check("déverrouillage « en échec » : la session est récupérée",
              session == "SESSION-XYZ")
        cs.store_set(cs.BW_SESSION_KEY, session, export=False)
        check("synchronisation possible malgré l'erreur de migration",
              cs.bw_sync(folder="Claude Secrets")["total"] > 0)
        try:
            cs.bw_unlock("mauvais")
            check("mot de passe refusé reste une vraie erreur", False)
        except cs.BwError as e:
            check("mot de passe refusé reste une vraie erreur",
                  "migration" not in str(e))
    finally:
        os.environ.pop("FAKE_BW_MIGRATOR_UNLOCK", None)


# ───────────────────────────── interface ─────────────────────────────────────

def test_gui(cs, tmp):
    print("\nInterface")
    # La synchro auto lit la configuration Bitwarden : on isole l'état et on
    # route `bw` vers le faux CLI, pour ne jamais toucher à ton vrai compte.
    cs.STATE = tmp / "state.json"
    fake_bw_env(tmp)
    pathlib.Path(os.environ["FAKE_BW_STATE"]).unlink(missing_ok=True)
    for var in ("GDK_PIXBUF_MODULE_FILE", "GDK_PIXBUF_MODULEDIR"):
        os.environ.pop(var, None)
    cs.store_set(PREFIX + "PRIVE", "valeur-privee-1", export=False)
    cs.save_pair(PREFIX + "PAIRE", "u@x.fr", "motdepasse-test")
    cs.detect = (lambda d=cs.detect: {**d(), "complete": True})
    cs.APP_ID = "fr.amphibee.ClaudeSecretsTests"

    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Gtk, Adw, GLib, Gdk

    captured = {}
    original_run = Adw.Application.run

    def patched(self, argv):
        captured["app"] = self
        return original_run(self, argv)

    Adw.Application.run = patched

    def walk(widget):
        yield widget
        child = widget.get_first_child()
        while child:
            yield from walk(child)
            child = child.get_next_sibling()

    def dialogs():
        return [w for w in Gtk.Window.list_toplevels()
                if isinstance(w, (Adw.MessageDialog, Adw.AboutWindow))]

    def run_checks(app):
        win = app.props.active_window
        check("le lancement part du cache du shell", win.preloaded)
        for dark in (False, True):
            provider, errors = Gtk.CssProvider(), []
            provider.connect("parsing-error", lambda *a: errors.append(a))
            provider.load_from_data(cs.theme_css(dark), -1)
            check(f"le CSS {'sombre' if dark else 'clair'} s'analyse sans erreur",
                  not errors)
        win.searchbar.set_key_capture_widget(None)
        win.search.set_text(PREFIX)
        win.show_all = True
        win.render()

        expander = next(w for w in walk(win) if isinstance(w, Adw.ExpanderRow)
                        and w.get_title() == PREFIX + "PAIRE")
        check("la recherche filtre sur les données en mémoire", True)
        expander.set_expanded(True)
        check("le détail est construit au dépliage", expander.filled)
        password_row = next(w for w in walk(expander)
                            if isinstance(w, Adw.ActionRow)
                            and w.get_title() == "Mot de passe")
        eye = next(w for w in walk(password_row) if isinstance(w, Gtk.Button)
                   and w.get_icon_name() == "view-reveal-symbolic")
        eye.emit("clicked")
        check("afficher le mot de passe ne replie pas la ligne",
              expander.get_expanded()
              and password_row.get_subtitle() == "motdepasse-test")

        win.render()
        again = next(w for w in walk(win) if isinstance(w, Adw.ExpanderRow)
                     and w.get_title() == PREFIX + "PAIRE")
        check("l'état déplié survit à une reconstruction", again.get_expanded())

        for action, param in (("new", None), ("setup", None), ("about", None),
                              ("shortcuts", None),
                              ("importenv", None),
                              ("edit", f"pair|{PREFIX}PAIRE")):
            before = len(dialogs())
            win.activate_action("win." + action,
                                GLib.Variant.new_string(param) if param else None)
            check(f"le dialogue « {action} » s'ouvre", len(dialogs()) > before)
            for d in dialogs():
                d.close()

        menu_buttons = [w for w in walk(win) if isinstance(w, Gtk.MenuButton)
                        and w.get_tooltip_text() == "Plus d'actions"]
        for b in menu_buttons[:1]:
            b.popup()
            b.popdown()
        check("le menu d'actions d'un secret s'ouvre", bool(menu_buttons))

        # suppression sans dialogue, annulable, qui conserve l'origine
        cs.store_set(PREFIX + "ORIGINE", "valeur-bw", export=True,
                     source="bitwarden:test")
        win.reload()
        for _ in range(200):          # lecture du trousseau : lente sous charge
            if PREFIX + "ORIGINE" in {e[1] for e in win.data or []}:
                break
            GLib.MainContext.default().iteration(False)
            time.sleep(0.1)
        reads = []
        real_store_all = cs.store_all
        cs.store_all = lambda *a, **k: (reads.append(1), real_store_all(*a, **k))[1]
        win.activate_action("win.delete",
                            GLib.Variant.new_string(f"single|{PREFIX}ORIGINE"))
        check("supprimer ne demande pas de confirmation",
              cs.store_get(PREFIX + "ORIGINE") is None)
        check("le cache shell suit la suppression",
              f"{PREFIX}ORIGINE=" not in cs.CACHE.read_text())
        key = str(win.trash_id)
        win.activate_action("win.undo", GLib.Variant.new_string(key))
        cs.store_all = real_store_all
        check("supprimer puis annuler ne relit pas le trousseau", not reads)
        check("le cache shell suit la restauration",
              f"{PREFIX}ORIGINE=" in cs.CACHE.read_text())
        check("le cache shell reste en 0600",
              oct(cs.CACHE.stat().st_mode & 0o777) == "0o600")
        snap = cs.store_snapshot(PREFIX + "ORIGINE")
        check("annuler restaure la valeur", snap and snap[0] == "valeur-bw")
        check("annuler conserve l'origine Bitwarden",
              snap and snap[2] == "bitwarden:test")
        check("annuler deux fois est sans effet",
              win.trash.get(key) is None)

        win.activate_action("win.delete",
                            GLib.Variant.new_string(f"pair|{PREFIX}PAIRE"))
        check("supprimer un identifiant retire les deux variables",
              cs.store_get(PREFIX + "PAIRE_USER") is None
              and cs.store_get(PREFIX + "PAIRE_PASSWORD") is None)
        win.activate_action("win.undo",
                            GLib.Variant.new_string(str(win.trash_id)))
        check("annuler restaure l'identifiant et le mot de passe",
              cs.store_get(PREFIX + "PAIRE_USER") == "u@x.fr"
              and cs.store_get(PREFIX + "PAIRE_PASSWORD") == "motdepasse-test")

        # recherche au clavier
        win.search.set_text(PREFIX)            # liste affichée : requête large
        win.render()
        win.search.set_text(PREFIX + "PRIVE")  # Entrée avant le « search-changed »
        win.copy_first()
        check("Entrée cible le premier résultat",
              win.results and win.results[0][1] == PREFIX + "PRIVE")
        check("↓ passe de la recherche à la liste",
              win.search_key(None, Gdk.KEY_Down, 0, 0) is True)
        win.search.set_text("zz-aucun-resultat-zz")
        win.copy_first()
        check("Entrée sans résultat ne fait rien", win.results == [])
        win.search.set_text(PREFIX)

        # import d'un .env collé
        win.activate_action("win.importenv")
        dialog = dialogs()[-1]
        view = next(w for w in walk(dialog) if isinstance(w, Gtk.TextView))
        view.get_buffer().set_text(
            f"# commentaire\nexport {PREFIX}ENV_A=\"a b\"\n{PREFIX}ENV_B=2\nligne invalide\n")
        dialog.response("import")
        check("l'import crée les secrets du .env collé",
              cs.store_get(PREFIX + "ENV_A") == "a b"
              and cs.store_get(PREFIX + "ENV_B") == "2")
        for d in dialogs():
            d.close()

        win.activate_action("win.edit",
                            GLib.Variant.new_string(f"single|{PREFIX}PRIVE"))
        dialog = dialogs()[-1]
        field = next(w for w in walk(dialog)
                     if isinstance(w, Adw.PasswordEntryRow))
        field.set_text("valeur-privee-2")
        dialog.response("save")
        state = {n: (v, e) for n, v, e in cs.store_all()}.get(PREFIX + "PRIVE")
        check("modification enregistrée", state and state[0] == "valeur-privee-2")
        check("un secret hors environnement le reste après modification",
              state and state[1] is False)

        started = time.perf_counter()
        win.search.set_text("")
        win.show_all = False
        win.render()
        check("affichage initial sous 1 s",
              (time.perf_counter() - started) < 1.0)

        # regroupement par service
        win.lookup_action("groupby").change_state(GLib.Variant.new_string("service"))
        check("le mode de regroupement est mémorisé",
              cs.state_get("group_by") == "service" and win.group_mode == "service")
        win.search.set_text("")
        win.render()
        zz = next((w for w in walk(win.box) if isinstance(w, Adw.ExpanderRow)
                   and w.get_title() == "Zztest"), None)
        check("les secrets de test forment un service", zz is not None)
        check("l'index est découpé par lettres",
              any(isinstance(w, Adw.PreferencesGroup) and w.get_title() == "Z"
                  for w in walk(win.box)))
        check("un groupe n'est construit qu'à l'ouverture", not zz.filled)
        zz.set_expanded(True)
        check("ouvrir un groupe liste ses entrées",
              zz.filled and any(isinstance(w, Adw.ExpanderRow)
                                and w.get_title() == PREFIX + "PAIRE"
                                for w in walk(zz)))
        for _ in range(40):                       # laisse GTK calculer la mise en page
            GLib.MainContext.default().iteration(False)
            time.sleep(0.02)
        nested = next(w for w in walk(zz) if isinstance(w, Gtk.ListBox)
                      and w.has_css_class("nested"))
        _, box = nested.compute_bounds(zz)
        check("le groupe déplié est aligné sur la ligne parente, sans retrait",
              round(box.get_x()) == 0 and round(box.get_width()) == round(zz.get_width()))
        revealer = nested.get_parent()
        check("aucune marge sous le groupe déplié",
              round(revealer.get_height()) == round(nested.get_height()))
        check("nos lignes n'usurpent pas la classe « entry » des champs d'Adwaita",
              not any(w.has_css_class("entry") for w in walk(zz)
                      if isinstance(w, (Adw.ActionRow, Adw.ExpanderRow)))
              and any(w.has_css_class("secret-item") for w in walk(zz)
                      if isinstance(w, Adw.ExpanderRow)))
        check("les lignes d'un groupe reprennent la pastille du service",
              all(a.get_text() == "Zztest"
                  for a in walk(zz) if isinstance(a, Adw.Avatar)))
        tone = f"tone-{cs.tone_index('Zztest')}"
        check("les lignes d'un groupe ont la même teinte que le service",
              all(a.has_css_class(tone)
                  for a in walk(zz) if isinstance(a, Adw.Avatar)))
        letter = next(w for w in walk(win.box) if isinstance(w, Adw.PreferencesGroup)
                      and w.get_title() == "Z")
        heading = next(w for w in walk(letter) if isinstance(w, Gtk.Label)
                       and w.has_css_class("heading"))
        check("la lettre de section est centrée sur la colonne des monogrammes",
              heading.get_xalign() == 0.5 and heading.get_size_request()[0] == 64)
        zz.set_expanded(False)
        started = time.perf_counter()
        win.render()
        check("affichage par service sous 1 s", (time.perf_counter() - started) < 1.0)
        win.search.set_text(PREFIX + "PRIVE")
        win.render()
        zz = next(w for w in walk(win.box) if isinstance(w, Adw.ExpanderRow)
                  and w.get_title() == "Zztest")
        check("peu de résultats : le groupe s'ouvre tout seul", zz.get_expanded())
        win.search.set_text("")
        win.render()
        zz = next(w for w in walk(win.box) if isinstance(w, Adw.ExpanderRow)
                  and w.get_title() == "Zztest")
        check("l'ouverture automatique n'est pas mémorisée", not zz.get_expanded())
        win.search.set_text(PREFIX + "PRIVE")
        win.copy_first()
        check("Entrée vise le premier résultat dans l'ordre des groupes",
              win.results and win.results[0][1] == PREFIX + "PRIVE")
        win.search.set_text("")

        win.domains = {PREFIX + "PRIVE": "x.autrenom.io",
                       PREFIX + "PAIRE": "y.autrenom.io"}
        win.regroup()
        check("l'adresse web range l'entrée dans le service de son domaine",
              any(isinstance(w, Adw.ExpanderRow) and w.get_title() == "Autrenom"
                  for w in walk(win.box)))
        win.domains = {}
        win.regroup()

        # groupe choisi à la main, par le dialogue
        cs.state_update(groups={"ZZTEST_FANTOME": "Fantôme"})
        win.group_overrides = {"ZZTEST_FANTOME": "Fantôme"}
        for d in dialogs():
            d.close()
        group_dialog = lambda: next((d for d in dialogs()
                                     if d.get_heading() == f"Groupe de {PREFIX}PRIVE"),
                                    None)
        win.activate_action("win.setgroup",
                            GLib.Variant.new_string(f"single|{PREFIX}PRIVE"))
        check("le dialogue « changer de groupe » s'ouvre", group_dialog() is not None)
        dialog = group_dialog()
        next(w for w in walk(dialog) if isinstance(w, Adw.EntryRow)
             and w.get_title() == "Nom du groupe").set_text("Clients zz")
        dialog.response("save")
        for d in dialogs():
            d.close()
        saved = cs.state_get("groups")
        check("le groupe choisi est enregistré", saved.get(PREFIX + "PRIVE") == "Clients zz")
        check("le choix d'une entrée disparue est purgé", "ZZTEST_FANTOME" not in saved)
        check("l'entrée apparaît dans le groupe choisi",
              any(isinstance(w, Adw.ExpanderRow) and w.get_title() == "Clients zz"
                  for w in walk(win.box)))
        win.search.set_text("clients zz")
        win.render()
        check("la recherche trouve aussi par nom de groupe",
              [e[1] for e in win.results] == [PREFIX + "PRIVE"])
        win.search.set_text("")
        win.activate_action("win.setgroup",
                            GLib.Variant.new_string(f"single|{PREFIX}PRIVE"))
        dialog = group_dialog()
        dialog.response("auto")
        for d in dialogs():
            d.close()
        check("« Automatique » retire le choix manuel",
              PREFIX + "PRIVE" not in cs.state_get("groups"))

        # synchronisation Bitwarden automatique (faux CLI, état isolé)
        calls = []
        real_sync = cs.bw_sync
        cs.bw_sync = lambda *a, **k: (calls.append(k), real_sync(*a, **k))[1]

        def wait(cond, seconds=30):
            end = time.time() + seconds
            while time.time() < end and not cond():
                GLib.MainContext.default().iteration(False)
                time.sleep(0.02)
            for _ in range(20):
                GLib.MainContext.default().iteration(False)
            return cond()

        win.last_sync = 0.0
        win.auto_sync()
        check("sans compte Bitwarden, aucune synchro auto", not calls)

        cs.bw_set_server("vault.exemple.fr")
        cs.store_set(cs.BW_SESSION_KEY,
                     cs.bw_login("o@exemple.fr", "bonmotdepasse"), export=False)
        cs.bw_conf({"email": "o@exemple.fr", "folder": "Claude Secrets"})
        win.auto_sync()
        wait(lambda: not win.syncing and PREFIX + "CLOUDFLARE" in win.items)
        check("la synchro auto importe le coffre", PREFIX + "CLOUDFLARE" in win.items)
        check("la synchro auto ne supprime jamais (pas de prune)",
              len(calls) == 1 and not calls[0].get("prune"))
        win.auto_sync()
        check("pas de nouvelle synchro avant l'intervalle minimal", len(calls) == 1)

        toggle = win.lookup_action("autosync")
        toggle.change_state(GLib.Variant.new_boolean(False))
        win.last_sync = 0.0
        win.auto_sync()
        check("désactivée, la synchro auto ne part pas",
              len(calls) == 1 and cs.bw_conf().get("auto_sync") is False)
        toggle.change_state(GLib.Variant.new_boolean(True))
        wait(lambda: len(calls) == 2 and not win.syncing)
        check("la réactiver relance une synchro", len(calls) == 2)

        win.syncing = True
        win.auto_sync(force=True)
        win.syncing = False
        check("jamais deux synchros en même temps", len(calls) == 2)

        cs.bw_run(["lock"])
        win.last_sync = 0.0
        before = len(dialogs())
        win.auto_sync()
        wait(lambda: len(calls) == 3 and not win.syncing)
        check("coffre verrouillé : aucun mot de passe réclamé d'office",
              len(calls) == 3 and not win.syncing and len(dialogs()) == before)
        cs.bw_sync = real_sync

        # une modification faite pendant une synchro ne doit pas être écrasée
        win.commit(sets=[(PREFIX + "COURSE", "v", True)])
        win.bw_done({"added": [PREFIX + "SYNC_NEW"], "updated": [], "removed": [],
                     "total": 1, "items": [(PREFIX + "SYNC_NEW", "x", True)]},
                    auto=True)
        check("la synchro n'écrase pas une modification faite entre-temps",
              PREFIX + "COURSE" in win.items and PREFIX + "SYNC_NEW" in win.items)

        # fermer masque la fenêtre au lieu de quitter ; rouvrir est instantané
        win.revealed.add(PREFIX + "PRIVE")
        win.search.set_text(PREFIX)
        win.close()
        check("fermer masque la fenêtre", not win.get_visible())
        check("masquer remet les valeurs affichées à zéro",
              not win.revealed and win.search.get_text() == "")
        check("une minuterie quitte l'application si elle reste masquée",
              win.idle_timer != 0)
        check("la fenêtre masquée ne contient plus aucune ligne",
              not any(isinstance(w, Adw.ActionRow) for w in walk(win.box)))
        time.sleep(0.5)                     # laisse passer les minuteurs de recherche
        for _ in range(20):
            GLib.MainContext.default().iteration(False)
        check("rien n'est reconstruit pendant qu'elle est masquée",
              not any(isinstance(w, Adw.ActionRow) for w in walk(win.box)))
        app.activate()
        check("relancer réaffiche la même fenêtre",
              win.get_visible() and app.props.active_window is win
              and win.idle_timer == 0)
        for _ in range(50):
            GLib.MainContext.default().iteration(False)
        check("la liste revient à la réouverture",
              any(isinstance(w, Adw.ActionRow) for w in walk(win.box)))
        check("la réouverture ne montre pas de spinner",
              not any(isinstance(w, Adw.StatusPage)
                      and w.get_title() == "Lecture du trousseau…"
                      for w in walk(win.box)))

        app.quit()
        return False

    def arm():
        app = captured.get("app")
        win = app.props.active_window if app else None
        if win and getattr(win, "data", None) is not None and not win.loading:
            GLib.timeout_add(300, run_checks, app)
            return False
        return True

    cs.state_update(group_by="type")    # les premières vérifications visent ce mode
    cs.refresh_cache()          # le cache est celui que lira la fenêtre au lancement
    GLib.timeout_add(100, arm)
    GLib.timeout_add_seconds(90, lambda: (print("  délai dépassé"),
                                          captured["app"].quit())[1])
    cs.gui()


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    cs = load_app()
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="claude-secrets-tests-"))
    try:
        if which in ("all", "core"):
            test_core(cs)
        if which in ("all", "bitwarden"):
            test_bitwarden(cs, tmp)
        if which in ("all", "gui"):
            test_gui(cs, tmp)
    finally:
        cleanup(cs)
        shutil.rmtree(tmp, ignore_errors=True)

    failed = [name for name, good in RESULTS if not good]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} test(s) réussi(s)")
    for name in failed:
        print("  échec :", name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
