#!/usr/bin/env bash
# Désinstalle Claude Secrets. Les secrets du trousseau ne sont PAS supprimés.
set -euo pipefail

say() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

/usr/bin/python3 - <<'PY'
import pathlib, re, json

HOME = pathlib.Path.home()
BEGIN, END = "# >>> claude-secrets >>>", "# <<< claude-secrets <<<"
MD_BEGIN, MD_END = "<!-- claude-secrets:début -->", "<!-- claude-secrets:fin -->"


def strip(path, begin, end):
    if not path.exists():
        return False
    t = path.read_text()
    if begin not in t or end not in t:
        return False
    a, b = t.index(begin), t.index(end) + len(end)
    path.write_text(t[:a].rstrip("\n") + "\n" + t[b:].lstrip("\n"))
    return True


for rc in (HOME / ".zshrc", HOME / ".bashrc"):
    if strip(rc, BEGIN, END):
        print(f"  bloc retiré de {rc.name}")

if strip(HOME / ".claude/CLAUDE.md", MD_BEGIN, MD_END):
    print("  règles retirées de ~/.claude/CLAUDE.md")

s = HOME / ".claude/settings.json"
if s.exists():
    try:
        d = json.loads(s.read_text())
        deny = d.get("permissions", {}).get("deny", [])
        keep = [r for r in deny
                if "claude-secrets" not in r
                and r not in ("Bash(env)", "Bash(env:*)", "Bash(printenv:*)",
                              "Bash(export -p)", "Read(**/.env)", "Read(**/.env.*)")]
        if len(keep) != len(deny):
            d["permissions"]["deny"] = keep
            # Ne pas laisser de structure vide que l'on n'avait pas créée
            if not keep:
                d["permissions"].pop("deny")
            if not d.get("permissions"):
                d.pop("permissions", None)
            s.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
            print("  garde-fous retirés de settings.json")
    except Exception as e:
        print(f"  settings.json inchangé ({e})")

for f in (HOME / ".local/share/applications/fr.amphibee.ClaudeSecrets.desktop",
          HOME / ".local/share/icons/hicolor/scalable/apps/fr.amphibee.ClaudeSecrets.svg",
          HOME / ".local/bin/claude-secrets",
          HOME / ".config/claude-secrets/state.json"):
    if f.exists():
        f.unlink()
        print(f"  supprimé : {f}")
PY

ok "Désinstallé."
echo
echo "  Tes secrets restent dans le trousseau. Pour les supprimer aussi,"
echo "  ouvre « Mots de passe et clés » (seahorse) et efface les entrées"
echo "  « Claude Secrets — … »."
