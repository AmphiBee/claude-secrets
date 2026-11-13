#!/bin/bash
# Lance une copie de DÉMO de l'application, sur un coffre FICTIF (service de trousseau zztest-demo), avec un faux
# Bitwarden, un état et un cache isolés. Identifiant d'application distinct : elle cohabite avec la vraie.
#   Tools/run-demo.sh [debug|release]
# Variables facultatives (version debug) : UI_SELECT=svc:BABE  UI_QUERY=babe  DARK=1  (captures d'écran)
set -euo pipefail
cd "$(dirname "$0")/.."
Tools/build-app.sh "${1:-debug}" >/dev/null
D="$PWD/build/demo"; rm -rf "$D"; mkdir -p "$D/bin"
cp ../tests/fake-bw "$D/bin/bw"; chmod +x "$D/bin/bw"; cp ../tests/vault.json "$D/fakevault.json"
APP="$D/Claude Secrets Démo.app"; ditto build/ClaudeSecrets.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier fr.amphibee.ClaudeSecrets.demo" -c "Set :CFBundleName Démo" \
  -c "Set :CFBundleDisplayName Démo" "$APP/Contents/Info.plist"
codesign --force --options runtime --sign - "$APP" >/dev/null 2>&1
CLAUDE_SECRETS_SERVICE=zztest-demo /usr/bin/python3 Tools/seed-demo.py
pkill -f "Démo.app/Contents/MacOS" 2>/dev/null || true; sleep 1
EXTRA=(); [ -n "${UI_SELECT:-}" ] && EXTRA+=(--env "CLAUDE_SECRETS_UI_SELECT=$UI_SELECT"); [ -n "${UI_QUERY:-}" ] && EXTRA+=(--env "CLAUDE_SECRETS_UI_QUERY=$UI_QUERY")
[ -n "${DARK:-}" ] && EXTRA+=(--env CLAUDE_SECRETS_UI_DARK=1); ARGS=()
open -n ${EXTRA[@]+"${EXTRA[@]}"} --env CLAUDE_SECRETS_SERVICE=zztest-demo --env CLAUDE_SECRETS_STATE="$D/state.json" --env XDG_RUNTIME_DIR="$D" \
  --env PATH="$D/bin:/usr/bin:/bin" --env FAKE_BW_STATE="$D/fakebw.json" --env FAKE_BW_VAULT="$D/fakevault.json" "$APP" ${ARGS[@]+"${ARGS[@]}"}
echo "Démo lancée (coffre fictif zztest-demo)."
