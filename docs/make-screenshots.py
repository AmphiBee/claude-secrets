#!/usr/bin/python3
"""Régénère les captures du README, sans toucher à tes vrais secrets.

    make screenshots          (ou : /usr/bin/python3 docs/make-screenshots.py)

L'application tourne sur un écran X virtuel (Xephyr) : seules ses propres fenêtres
y existent, donc une capture ne peut jamais montrer autre chose. Elle est nourrie de
données fictives : le trousseau, le cache du shell et l'état local réels sont
remplacés (et toute écriture est interdite).

Prérequis : Xephyr, xwd, xwininfo, Pillow (python3-pil).
Une petite fenêtre « Xephyr » apparaît sur ton écran pendant l'opération.
"""
import importlib.machinery as M
import importlib.util as U
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "screenshots"
W, H = 880, 740
DISPLAY = ":77"

# ───────────────────────── données fictives ─────────────────────────
# Noms de clients et de projets inventés ; services courants (publics).


def pair(base, user="contact@exemple.fr"):
    return [(f"{base}_USER", user, True), (f"{base}_PASSWORD", "exemple-mot-de-passe", True)]


def single(name, exported=True):
    return [(name, "exemple-valeur-secrete", exported)]


def aws(profile):
    return [(f"AWS_{profile}_ACCESS_KEY_ID", "AKIAEXEMPLE0000000", False),
            (f"AWS_{profile}_SECRET_ACCESS_KEY", "exemple-secret-aws", False)]


DEMO = (
    aws("BOREALE") + aws("DEFAULT")
    + pair("ALGOLIA_COM") + single("ALGOLIA_ADMIN_API_KEY")
    + pair("AIRTABLE_COM") + single("AIRTABLE_TOKEN")
    + pair("BOREALE_FR", "studio@boreale.fr") + pair("BOREALE_PREPROD_STUDIO_FR")
    + pair("PMA_BOREALE_DOCKER", "root") + single("BOREALE_STRIPE_SECRET_KEY")
    + pair("BREVO_COM") + single("BREVO_API_KEY")
    + pair("CASCADE_FR") + pair("CASCADE_DOCKER_LOCALHOST", "admin")
    + pair("WP_CASCADE_FR", "editeur")
    + pair("CLOUDFLARE_COM") + single("CLOUDFLARE_API_TOKEN") + single("CLOUDFLARE_ZONE_TOKEN")
    + pair("DATADOG_COM") + single("DATADOG_API_KEY") + single("DATADOG_APP_KEY")
    + pair("GITHUB_COM") + single("GITHUB_TOKEN") + single("RENOVATE_GITHUB_TOKEN")
    + pair("GITLAB_COM") + single("GITLAB_PERSONAL_ACCESS_TOKEN")
    + pair("ACCOUNTS_GOOGLE_COM") + single("GOOGLE_CLIENT_ID") + single("GOOGLE_CLIENT_SECRET")
    + pair("CRM_COMMERCIAL") + single("HUBSPOT_API_KEY")
    + pair("LOGIN_MAILCHIMP_COM") + single("MAILCHIMP_API_KEY")
    + pair("NOVA_STUDIO_FR", "hello@nova.fr") + pair("NOVA_PREPROD_AGENCE_FR")
    + pair("PMA_NOVA_DOCKER", "root") + single("NOVA_DB_PASSWORD", exported=False)
    + pair("NOTION_SO") + single("NOTION_TOKEN")
    + single("OPENAI_API_KEY") + single("OPENAI_ORG_ID")
    + pair("SENTRY_IO") + single("SENTRY_AUTH_TOKEN")
    + pair("SLACK_COM") + single("SLACK_BOT_TOKEN") + single("SLACK_WEBHOOK_URL")
    + pair("DASHBOARD_STRIPE_COM") + single("STRIPE_SECRET_KEY") + single("STRIPE_WEBHOOK_SECRET")
    + pair("VERCEL_COM") + single("VERCEL_TOKEN")
    + pair("WIKI_INTERNE") + pair("MONITORING_INTERNE")
    + pair("MAILGUN_COM") + pair("CANVA_COM") + pair("FIGMA_COM") + pair("LINEAR_APP")
    + single("RESEND_API_KEY") + single("BACKUP_ENCRYPTION_PASSPHRASE", exported=False)
)
DEMO_STATE = {
    "group_by": "service",
    "domains": {"CRM_COMMERCIAL": "app.hubspot.com"},
    "groups": {"WIKI_INTERNE": "Outils internes", "MONITORING_INTERNE": "Outils internes"},
}


# ───────────────────────── écran virtuel ─────────────────────────

def start_xephyr():
    sock = pathlib.Path(f"/tmp/.X11-unix/X{DISPLAY[1:]}")
    proc = subprocess.Popen(["Xephyr", DISPLAY, "-screen", f"{W}x{H}", "-ac", "-br",
                             "-nolisten", "tcp", "-title", "Captures du README"],
                            stderr=subprocess.DEVNULL)
    for _ in range(100):
        if sock.exists():
            time.sleep(0.5)
            return proc
        time.sleep(0.1)
    proc.kill()
    sys.exit("Xephyr n'a pas démarré.")


def grab(args, name):
    """Capture via xwd (sur l'écran virtuel) et retourne une image Pillow."""
    from PIL import Image
    raw = OUT.parent / f".{name}.xwd"
    subprocess.run(["xwd", "-display", DISPLAY, *args, "-out", str(raw)], check=True)
    data = raw.read_bytes()
    raw.unlink()
    h = struct.unpack(">25I", data[:100])
    width, height, bpl, ncolors = h[4], h[5], h[12], h[19]
    offset = h[0] + ncolors * 12
    return Image.frombytes("RGB", (width, height), data[offset:], "raw", "BGRX", bpl, 1)


def frame(img, radius=14, margin=44, shadow=26):
    """Coins arrondis, ombre douce et fond transparent : une fenêtre de bureau."""
    from PIL import Image, ImageDraw, ImageFilter
    w, h = img.size
    canvas = Image.new("RGBA", (w + 2 * margin, h + 2 * margin), (0, 0, 0, 0))
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle(
        (margin, margin + 10, margin + w, margin + h + 10), radius, fill=(40, 25, 15, 110))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(shadow / 2)))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius, fill=255)
    canvas.paste(img.convert("RGBA"), (margin, margin), mask)
    return canvas


def save(img, name):
    OUT.mkdir(parents=True, exist_ok=True)
    frame(img).save(OUT / f"{name}.png", optimize=True)
    print("  ✓", name, flush=True)


def unblack(shot, behind):
    """Sans compositeur, le popover est un rectangle aux coins noirs : on y remet ce
    qu'il cachait (la capture prise juste avant son ouverture)."""
    from PIL import ImageChops
    r, g, b = shot.split()
    dark = ImageChops.lighter(ImageChops.lighter(r, g), b).point(
        lambda v: 255 if v == 0 else 0)
    shot.paste(behind, mask=dark)
    return shot


def window_id(title):
    out = subprocess.run(["xwininfo", "-display", DISPLAY, "-name", title],
                         capture_output=True, text=True).stdout
    return re.search(r"Window id: (0x[0-9a-f]+)", out).group(1)


# ───────────────────────── l'application ─────────────────────────

def main():
    xephyr = start_xephyr()
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="cs-docs-"))
    os.environ.update(DISPLAY=DISPLAY, GDK_BACKEND="x11", GSK_RENDERER="cairo",
                      GDK_DEBUG="gl-disable")
    for var in ("GDK_PIXBUF_MODULE_FILE", "GDK_PIXBUF_MODULEDIR"):
        os.environ.pop(var, None)
    try:
        run(tmp)
    finally:
        xephyr.kill()
        shutil.rmtree(tmp, ignore_errors=True)


def run(tmp):
    import json
    loader = M.SourceFileLoader("cs", str(ROOT / "claude-secrets"))
    spec = U.spec_from_loader("cs", loader)
    cs = U.module_from_spec(spec)
    loader.exec_module(cs)

    cs.APP_ID = "fr.amphibee.ClaudeSecretsDocs"
    cs.STATE = tmp / "state.json"
    cs.STATE.write_text(json.dumps(DEMO_STATE))
    cs.detect = lambda: {"complete": True}

    # Rien de réel : ni trousseau, ni cache du shell, ni écriture.
    def forbidden(*_a, **_k):
        raise RuntimeError("écriture interdite pendant les captures")
    cs.store_all = lambda only_exported=False: sorted(
        i for i in DEMO if i[2] or not only_exported)
    cs.store_meta = forbidden
    cs.read_cache = lambda: []
    cs.write_cache = cs.refresh_cache = lambda *a, **k: None
    cs.store_set = cs.store_del = cs.store_snapshot = forbidden

    import gi
    gi.require_version("Adw", "1")
    gi.require_version("Gtk", "4.0")
    from gi.repository import Adw, GLib, Gtk

    captured = {}
    original_run = Adw.Application.run
    from gi.repository import Gdk

    def calm_pointer():
        """Retire l'état survol (le pointeur de l'écran virtuel reste au centre) et
        l'ombre des popovers (sans compositeur, elle se dessine sur du noir)."""
        css = Gtk.CssProvider()
        css.load_from_data("row:hover, row.header:hover { background-color: transparent; }\n"
                           "popover > contents, popover > arrow { box-shadow: none; }", -1)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)

    def patched(self, argv):
        captured["app"] = self
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_LIGHT)
        return original_run(self, argv)
    Adw.Application.run = patched

    def walk(widget):
        yield widget
        child = widget.get_first_child()
        while child:
            yield from walk(child)
            child = child.get_next_sibling()

    def find(win, title):
        return next((x for x in walk(win.box)
                     if isinstance(x, Adw.ExpanderRow) and x.get_title() == title), None)

    def scheme(mode):
        Adw.StyleManager.get_default().set_color_scheme(
            Adw.ColorScheme.FORCE_DARK if mode == "dark" else Adw.ColorScheme.FORCE_LIGHT)

    def dialog(title):
        for d in Gtk.Window.list_toplevels():
            if isinstance(d, Adw.MessageDialog):
                d.set_title(title)
                return d

    def scenes(win, app):
        win.set_default_size(W, H)
        calm_pointer()
        yield 2.2                                   # liste prête + entrée en fondu
        save(grab(["-root"], "a"), "service-clair")
        scheme("dark")
        yield 1.2
        save(grab(["-root"], "a"), "service-sombre")
        scheme("light")
        yield 1.0

        find(win, "Boreale").set_expanded(True)     # un projet, puis le détail d'une entrée
        yield 0.6
        find(win, "BOREALE_FR").set_expanded(True)
        yield 0.9
        scroller = win.box.get_ancestor(Gtk.ScrolledWindow)
        _, bounds = find(win, "Boreale").compute_bounds(win.box)
        scroller.get_vadjustment().set_value(max(0, bounds.get_y() - 120))
        yield 0.6
        save(grab(["-root"], "a"), "groupe-deplie")
        scroller.get_vadjustment().set_value(0)
        find(win, "BOREALE_FR").set_expanded(False)
        find(win, "Boreale").set_expanded(False)

        win.searchbar.set_search_mode(True)
        win.search.set_text("stripe")
        yield 1.4
        save(grab(["-root"], "a"), "recherche")
        win.search.set_text("")
        win.searchbar.set_search_mode(False)
        yield 1.0

        button = next(w for w in walk(win) if isinstance(w, Gtk.MenuButton)
                      and w.get_tooltip_text() == "Menu principal")
        behind = grab(["-root"], "a")
        button.popup()
        yield 0.9
        save(unblack(grab(["-root"], "a"), behind), "menu")
        button.popdown()
        yield 0.5

        win.lookup_action("groupby").change_state(GLib.Variant.new_string("type"))
        yield 1.6
        save(grab(["-root"], "a"), "par-type")
        win.lookup_action("groupby").change_state(GLib.Variant.new_string("service"))
        yield 1.0

        win.activate_action("win.new")
        yield 0.8
        d = dialog("CS-DLG")
        yield 0.5
        save(grab(["-id", window_id("CS-DLG")], "a"), "nouveau-secret")
        d.close()
        yield 0.5

        win.activate_action("win.setgroup", GLib.Variant.new_string("pair|WIKI_INTERNE"))
        yield 0.8
        d = dialog("CS-DLG")
        yield 0.5
        save(grab(["-id", window_id("CS-DLG")], "a"), "changer-groupe")
        d.close()
        yield 0.3
        app.quit()

    def start():
        app = captured.get("app")
        win = getattr(app, "win", None) if app else None
        if win is None or win.loading or not win.data:
            return True
        it = scenes(win, app)

        def step():
            try:
                delay = next(it)
            except StopIteration:
                return False
            GLib.timeout_add(int(delay * 1000), step)
            return False
        step()
        return False

    GLib.timeout_add(300, start)
    GLib.timeout_add(120_000, lambda: (captured["app"].quit(), False)[1])
    print("Captures :", flush=True)
    cs.gui()


if __name__ == "__main__":
    main()
