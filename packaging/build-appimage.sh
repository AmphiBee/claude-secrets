#!/usr/bin/env bash
# Construit dist/Claude_Secrets-<version>-x86_64.AppImage.
# L'image embarque Python et GTK 4 : elle est construite avec la glibc de CETTE
# machine et tourne sur toute distribution qui en a une plus récente.
# Prérequis : python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1, gir1.2-secret-1, squashfs-tools, curl.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' claude-secrets)"
OUT="dist/Claude_Secrets-${VERSION}-x86_64.AppImage"
APPDIR="dist/AppDir"
RUNTIME="dist/.cache/runtime-x86_64"
mkdir -p dist/.cache

# Le « runtime » est le petit programme en tête de l'AppImage qui monte l'image
# (type 2, statique : aucun libfuse2 à installer chez l'utilisateur).
if [ ! -s "$RUNTIME" ]; then
  curl -fsSL -o "$RUNTIME" \
    https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64
fi
head -c 4 "$RUNTIME" | grep -q $'\x7fELF' || { echo "runtime invalide" >&2; exit 1; }

echo "→ assemblage de l'AppDir"
/usr/bin/python3 packaging/appimage/assemble.py "$APPDIR"
echo "→ compression"
mksquashfs "$APPDIR" dist/.cache/app.squashfs -root-owned -noappend -quiet \
  -comp zstd -Xcompression-level 15 -b 256K
cat "$RUNTIME" dist/.cache/app.squashfs > "$OUT"
chmod +x "$OUT"
rm -rf "$APPDIR" dist/.cache/app.squashfs
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
