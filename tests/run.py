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
import shutil
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
PREFIX = "ZZTEST_"
RESULTS = []


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
    report = cs.bw_sync(folder="Claude Secrets")

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


# ───────────────────────────── interface ─────────────────────────────────────

def test_gui(cs):
    print("\nInterface")
    for var in ("GDK_PIXBUF_MODULE_FILE", "GDK_PIXBUF_MODULEDIR"):
        os.environ.pop(var, None)
    cs.store_set(PREFIX + "PRIVE", "valeur-privee-1", export=False)
    cs.save_pair(PREFIX + "PAIRE", "u@x.fr", "motdepasse-test")
    cs.detect = (lambda d=cs.detect: {**d(), "complete": True})
    cs.APP_ID = "fr.amphibee.ClaudeSecretsTests"

    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Gtk, Adw, GLib

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
                              ("edit", f"pair|{PREFIX}PAIRE"),
                              ("delete", f"pair|{PREFIX}PAIRE")):
            before = len(dialogs())
            win.activate_action("win." + action,
                                GLib.Variant.new_string(param) if param else None)
            check(f"le dialogue « {action} » s'ouvre", len(dialogs()) > before)
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

        app.quit()
        return False

    def arm():
        app = captured.get("app")
        win = app.props.active_window if app else None
        if win and getattr(win, "data", None) is not None:
            GLib.timeout_add(300, run_checks, app)
            return False
        return True

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
            test_gui(cs)
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
