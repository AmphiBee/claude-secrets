#!/bin/bash
# Compile et installe « Claude Secrets.app » dans /Applications (ou le dossier donné en argument).
#   Tools/install-app.sh [dossier]
# L'application en cours est fermée proprement ; elle n'est PAS relancée (au premier lancement, macOS
# demande l'accès au trousseau : choisis « Toujours autoriser »).
set -euo pipefail
cd "$(dirname "$0")/.."
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/Claude Secrets.app"

Tools/build-app.sh release

if pgrep -x ClaudeSecrets >/dev/null; then
  echo "Fermeture de l'application en cours…"
  osascript -e 'tell application id "fr.amphibee.ClaudeSecrets" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x ClaudeSecrets >/dev/null || break; sleep 0.5; done
  if pgrep -x ClaudeSecrets >/dev/null; then
    echo "L'application ne s'est pas fermée : ferme-la (⌘Q) puis relance cette commande." >&2; exit 1
  fi
fi

# Une ancienne copie du même nom est remplacée ; ditto garde la signature et les attributs.
rm -rf "$DEST"
ditto build/ClaudeSecrets.app "$DEST"
codesign --verify --deep --strict "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
echo
echo "Installé : $DEST"
echo "Signature : $(codesign -dr - "$DEST" 2>&1 | grep -o 'leaf = H"[0-9a-f]*"\|cdhash H"[0-9a-f]*"' | head -1)"
echo "Lance-le avec :  open -a \"Claude Secrets\""
