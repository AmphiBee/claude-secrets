#!/usr/bin/env bash
# Construit dist/claude-secrets_<version>_all.deb — sans root.
# Le paquet installe la commande, le lanceur et l'icône pour tout le système ;
# l'intégration dans le dossier personnel (shell, règles Claude Code) reste à
# faire une fois par utilisateur : `claude-secrets install` ou l'écran d'accueil.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' claude-secrets)"
PKG="claude-secrets_${VERSION}_all"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p dist "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/doc/claude-secrets" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/scalable/apps"

install -m 755 claude-secrets "$STAGE/usr/bin/claude-secrets"

# Lanceur et icône : générés depuis le code, pour rester identiques à ceux de install.sh.
/usr/bin/python3 - "$STAGE" <<'PY'
import importlib.machinery as M, importlib.util as U, pathlib, sys
stage = pathlib.Path(sys.argv[1])
loader = M.SourceFileLoader("cs", "claude-secrets")
cs = U.module_from_spec(U.spec_from_loader("cs", loader)); loader.exec_module(cs)
(stage / f"usr/share/applications/{cs.APP_ID}.desktop").write_text(
    cs.DESKTOP_ENTRY.format(exe="claude-secrets"))
(stage / f"usr/share/icons/hicolor/scalable/apps/{cs.APP_ID}.svg").write_text(cs.ICON_SVG)
PY

install -m 644 README.md "$STAGE/usr/share/doc/claude-secrets/README.md"
gzip -9n -c CHANGELOG.md > "$STAGE/usr/share/doc/claude-secrets/changelog.gz"
install -m 644 packaging/deb/copyright "$STAGE/usr/share/doc/claude-secrets/copyright"
install -m 755 packaging/deb/postinst packaging/deb/postrm "$STAGE/DEBIAN/"

SIZE="$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)"
sed -e "s/@VERSION@/${VERSION}/" -e "s/@SIZE@/${SIZE}/" packaging/deb/control > "$STAGE/DEBIAN/control"

find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE/usr/share" -type f -exec chmod 644 {} +
dpkg-deb --root-owner-group --build "$STAGE" "dist/${PKG}.deb" >/dev/null
echo "✓ dist/${PKG}.deb ($(du -h "dist/${PKG}.deb" | cut -f1))"
