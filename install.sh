#!/usr/bin/env bash
# Installateur de Claude Secrets.
# Usage :  ./install.sh
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-secrets"

say()  { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$SRC" ] || die "claude-secrets introuvable à côté de ce script."

# ── 1. Dépendances ───────────────────────────────────────────────────────────
say "Vérification des dépendances…"
missing=0
/usr/bin/python3 - <<'PY' || missing=1
import sys
try:
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    gi.require_version("Secret", "1")
    from gi.repository import Gtk, Adw, Secret  # noqa: F401
except Exception as e:
    print(f"  manquant : {e}", file=sys.stderr)
    sys.exit(1)
PY

if [ "$missing" = 1 ]; then
  warn "Bibliothèques système manquantes."
  if command -v apt-get >/dev/null; then
    PKGS="python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 gir1.2-secret-1 gnome-keyring"
    CMD="sudo apt-get install -y $PKGS"
  elif command -v dnf >/dev/null; then
    CMD="sudo dnf install -y python3-gobject gtk4 libadwaita libsecret gnome-keyring"
  elif command -v pacman >/dev/null; then
    CMD="sudo pacman -S --needed python-gobject gtk4 libadwaita libsecret gnome-keyring"
  else
    die "Distribution non reconnue. Installe : python3-gi, GTK 4, libadwaita, libsecret, gnome-keyring."
  fi
  echo
  echo "  Commande à lancer (c'est la seule étape qui demande sudo) :"
  echo "    $CMD"
  echo
  read -r -p "  L'exécuter maintenant ? [o/N] " r
  case "$r" in
    [oOyY]*) eval "$CMD" ;;
    *) die "Installe les dépendances puis relance ./install.sh" ;;
  esac
fi
ok "Dépendances présentes."

# ── 2. Copie de la commande ──────────────────────────────────────────────────
ACTION="Installation"
if [ -x "$BIN_DIR/claude-secrets" ]; then
  # Les versions < 1.1.0 ne connaissent pas `version` et affichent leur aide :
  # on n'accepte que ce qui ressemble vraiment à un numéro de version.
  ANCIENNE="$("$BIN_DIR/claude-secrets" version 2>/dev/null \
              | grep -oE 'Claude Secrets [0-9]+\.[0-9]+\.[0-9]+' || true)"
  [ -n "$ANCIENNE" ] || ANCIENNE="une version antérieure"
  ACTION="Mise à jour depuis $ANCIENNE"
fi
mkdir -p "$BIN_DIR"
# La fenêtre masquée garde l'application en mémoire : sans l'arrêter, on
# continuerait à faire tourner l'ancienne version après la mise à jour.
if command -v gapplication >/dev/null 2>&1 \
   && gapplication action fr.amphibee.ClaudeSecrets quit 2>/dev/null; then
  ok "Ancienne instance de l'application arrêtée."
fi
install -m 755 "$SRC" "$BIN_DIR/claude-secrets"
ok "$ACTION → $("$BIN_DIR/claude-secrets" version)"

# ── 3. Intégration (shell, règles Claude Code, lanceur) ──────────────────────
say "Déploiement dans le dossier personnel…"
"$BIN_DIR/claude-secrets" install

echo
ok "Terminé."
echo
echo "  Si l'application était ouverte, ferme-la et relance-la."
echo "  Ouvre un nouveau terminal, puis :"
echo "    claude-secrets            # interface graphique"
echo "    claude-secrets set NOM    # ajouter une clé"
echo "    claude-secrets doctor     # vérifier l'installation"
