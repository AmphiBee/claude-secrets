#!/usr/bin/python3
"""Assemble l'AppDir de l'AppImage depuis la machine de construction.

Embarque Python, PyGObject, GTK 4, libadwaita, libsecret et leurs dépendances. Les
bibliothèques qui doivent rester celles de l'hôte (glibc, GL/EGL, X11, Wayland,
libstdc++) sont exclues : les embarquer casserait les pilotes graphiques.
Usage : assemble.py <AppDir>
"""
import importlib.machinery as M
import importlib.util as U
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
APPDIR = pathlib.Path(sys.argv[1]).resolve()   # absolu : le cache des chargeurs l'est aussi
MULTIARCH = pathlib.Path("/usr/lib/x86_64-linux-gnu")
LIB = APPDIR / "usr/lib/x86_64-linux-gnu"
PYVER = "3.10"

EXCLUDE = re.compile(
    r"^(ld-linux|libc\.so|libm\.so|libdl\.so|libpthread|librt\.so|libutil\.so|libresolv|"
    r"libnss|libanl|libmvec|libBrokenLocale|libthread_db|libstdc\+\+|libgcc_s|"
    r"libGL|libEGL|libOpenGL|libGLX|libGLdispatch|libdrm|libgbm|libX11|libxcb|libwayland)")


def run(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


def copy_tree(src, dst, ignore=()):
    shutil.copytree(src, dst, symlinks=False, ignore_dangling_symlinks=True,
                    ignore=shutil.ignore_patterns(*ignore), dirs_exist_ok=True)


def main():
    if APPDIR.exists():
        shutil.rmtree(APPDIR)
    (APPDIR / "usr/bin").mkdir(parents=True)
    LIB.mkdir(parents=True)

    # Python : l'interpréteur, la bibliothèque standard, PyGObject.
    shutil.copy2(f"/usr/bin/python{PYVER}", APPDIR / "usr/bin/python3")
    copy_tree(f"/usr/lib/python{PYVER}", APPDIR / f"usr/lib/python{PYVER}",
              ("__pycache__", "test", "tests", "idlelib", "tkinter", "turtledemo",
               "lib2to3", "ensurepip", "config-*", "*.pyc"))
    copy_tree("/usr/lib/python3/dist-packages/gi",
              APPDIR / "usr/lib/python3/dist-packages/gi", ("__pycache__",))

    # Bibliothèques natives : la fermeture de dépendances de chaque point d'entrée.
    roots = [APPDIR / "usr/bin/python3"]
    roots += list((APPDIR / f"usr/lib/python{PYVER}/lib-dynload").glob("*.so"))
    roots += list((APPDIR / "usr/lib/python3/dist-packages/gi").glob("_gi*.so"))
    roots += [MULTIARCH / n for n in ("libgtk-4.so.1", "libadwaita-1.so.0",
                                      "libsecret-1.so.0", "libgirepository-1.0.so.1",
                                      "librsvg-2.so.2")]
    loaders_src = MULTIARCH / "gdk-pixbuf-2.0/2.10.0/loaders"
    roots += list(loaders_src.glob("*.so"))
    libs = {}
    for root in roots:
        for line in run("ldd", str(root), env={"LD_LIBRARY_PATH": str(LIB)}).splitlines():
            m = re.match(r"\s*(\S+) => (/\S+)", line)
            if m and not EXCLUDE.match(m.group(1)):
                libs.setdefault(m.group(1), m.group(2))
    # Les points d'entrée eux-mêmes aussi : ldd ne liste que leurs dépendances, et un
    # libsecret ou libadwaita absent de l'image serait pris chez l'hôte, avec une
    # GLib qui n'est pas la sienne (« undefined symbol »).
    for root in roots:
        if root.parent == MULTIARCH:
            libs.setdefault(root.name, str(root.resolve()))
    for soname, real in libs.items():
        shutil.copy2(real, LIB / soname)
    print(f"  {len(libs)} bibliothèques embarquées")

    # Introspection, chargeurs d'images, schémas GSettings, icônes.
    copy_tree(MULTIARCH / "girepository-1.0", LIB / "girepository-1.0")
    pix = LIB / "gdk-pixbuf-2.0/2.10.0/loaders"
    copy_tree(loaders_src, pix)
    query = MULTIARCH / "gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"
    cache = run(str(query), *map(str, pix.glob("*.so")),
                env={"LD_LIBRARY_PATH": str(LIB)}).replace(str(APPDIR), "@APPDIR@")
    (LIB / "gdk-pixbuf-2.0/loaders.cache.in").write_text(cache)

    (LIB / "gio/modules").mkdir(parents=True)
    schemas = APPDIR / "usr/share/glib-2.0/schemas"
    schemas.mkdir(parents=True)
    for pattern in ("org.gtk.gtk4.*", "org.gtk.Settings.*", "org.gnome.desktop.*"):
        for xml in pathlib.Path("/usr/share/glib-2.0/schemas").glob(pattern + ".gschema.xml"):
            shutil.copy2(xml, schemas)
    run("glib-compile-schemas", str(schemas))

    icons = APPDIR / "usr/share/icons"
    for theme in ("Adwaita", "hicolor"):
        src = pathlib.Path("/usr/share/icons") / theme
        (icons / theme).mkdir(parents=True)
        shutil.copy2(src / "index.theme", icons / theme / "index.theme")
    for sub in ("scalable", "symbolic"):
        if (pathlib.Path("/usr/share/icons/Adwaita") / sub).exists():
            copy_tree(pathlib.Path("/usr/share/icons/Adwaita") / sub, icons / "Adwaita" / sub)

    # L'application, son lanceur, son icône, et AppRun.
    loader = M.SourceFileLoader("cs", str(ROOT / "claude-secrets"))
    cs = U.module_from_spec(U.spec_from_loader("cs", loader))
    loader.exec_module(cs)
    shutil.copy2(ROOT / "claude-secrets", APPDIR / "usr/bin/claude-secrets")
    (APPDIR / f"{cs.APP_ID}.desktop").write_text(cs.DESKTOP_ENTRY.format(exe="claude-secrets"))
    (APPDIR / f"{cs.APP_ID}.svg").write_text(cs.ICON_SVG)
    (APPDIR / ".DirIcon").symlink_to(f"{cs.APP_ID}.svg")
    app_run = APPDIR / "AppRun"
    shutil.copy2(ROOT / "packaging/appimage/AppRun", app_run)
    app_run.chmod(0o755)


main()
