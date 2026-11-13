#!/usr/bin/python3
"""Recensement Bitwarden : combien d'éléments `bw` renvoie, et combien deviennent des secrets. AUCUN nom,
AUCUNE valeur n'est affichée (seulement des nombres), donc la sortie peut être partagée.

    export BW_SESSION=$(bw unlock --raw)     # dans ton Terminal ; le mot de passe est saisi masqué
    macos/Tools/bw-census.py

Ne lit ni n'écrit le trousseau ni le coffre de Claude Secrets.
"""
import collections, importlib.machinery as M, importlib.util as U, json, os, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
os.environ.setdefault("CLAUDE_SECRETS_SERVICE", "zztest-census")      # par sécurité : jamais le vrai service
sys.path.insert(0, str(pathlib.Path.home() / ".local/share/claude-secrets/shim"))
loader = M.SourceFileLoader("cs", str(ROOT / "claude-secrets"))
cs = U.module_from_spec(U.spec_from_loader("cs", loader)); loader.exec_module(cs)

if not os.environ.get("BW_SESSION"):
    sys.exit("Définis d'abord BW_SESSION :  export BW_SESSION=$(bw unlock --raw)")

def bw(*args):
    p = subprocess.run(["bw", *args], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("bw a échoué : " + (p.stderr.strip().splitlines() or ["?"])[0])
    return json.loads(p.stdout or "[]")

folders = {f["id"]: i + 1 for i, f in enumerate(bw("list", "folders"))}
configured = (cs.bw_conf().get("folder"))
cfg_id = next((f["id"] for f in bw("list", "folders") if f.get("name") == configured), None) if configured else None
items = bw("list", "items")
TYPES = {1: "identifiant", 2: "note sécurisée", 3: "carte", 4: "identité", 5: "clé SSH"}

print(f"Éléments renvoyés par `bw list items` : {len(items)}")
print("\nPar type :")
for t, n in sorted(collections.Counter(i.get("type") for i in items).items(), key=lambda x: -x[1]):
    print(f"  {TYPES.get(t, 'type ' + str(t))} : {n}")
print("\nPar dossier (numéros anonymes) :")
per = collections.Counter(("racine (sans dossier)" if not i.get("folderId") else f"dossier {folders.get(i['folderId'], '?')}"
                           + (" ← réglage actuel" if i.get("folderId") == cfg_id and cfg_id else "")) for i in items)
for k, n in sorted(per.items(), key=lambda x: -x[1]):
    print(f"  {k} : {n}")
print(f"\nRéglage actuel de la CLI : {'tout le coffre' if configured == '' else 'racine' if configured == '/' else 'un dossier nommé' if configured else 'par défaut'}")

produce, skipped, names = 0, collections.Counter(), collections.defaultdict(int)
for it in items:
    got = cs.bw_map([it])
    if got:
        produce += 1
        for n, _v, _e in got:
            names[n] += 1
    else:
        login = it.get("login") or {}
        reason = ("type sans identifiant (note, carte, identité…)" if it.get("type") != 1 else
                  "identifiant sans mot de passe ni champ masqué" if not login.get("password") else "nom vide")
        skipped[reason] += 1
print(f"\nÉléments qui donnent au moins un secret : {produce} sur {len(items)}")
for r, n in skipped.most_common():
    print(f"  ignorés — {r} : {n}")
dup = {n: c for n, c in names.items() if c > 1}
print(f"\nSecrets distincts obtenus : {len(names)}")
print(f"Noms de variable en collision (un élément en écrase un autre) : {len(dup)} noms, "
      f"soit {sum(dup.values()) - len(dup)} élément(s) perdu(s)")

# Collisions au niveau des éléments : même nom d'élément (donc même variable) pour plusieurs éléments.
by_base = collections.defaultdict(list)
for it in items:
    if cs.bw_map([it]):
        by_base[cs.bw_slug(next((f.get("value") for f in it.get("fields") or [] if f.get("name") == cs.BW_NAME_FIELD), None) or it.get("name"))].append(it)
groups = {b: v for b, v in by_base.items() if len(v) > 1}
creds = lambda it: ((it.get("login") or {}).get("username"), (it.get("login") or {}).get("password"))
real = {b: len({creds(i) for i in v}) for b, v in groups.items()}
print(f"\nNoms d'élément partagés par plusieurs éléments : {len(groups)} noms, {sum(len(v) for v in groups.values())} éléments")
print(f"  doublons exacts (mêmes identifiant et mot de passe, sans perte) : {sum(len(v) - n for (b, v), n in zip(groups.items(), real.values()))} éléments")
print(f"  accès réellement différents écrasés : {sum(n - 1 for n in real.values())}")
print(f"  groupes de taille 2 / 3 / 4 et plus : {sum(1 for v in groups.values() if len(v) == 2)} / "
      f"{sum(1 for v in groups.values() if len(v) == 3)} / {sum(1 for v in groups.values() if len(v) >= 4)}")
same_dir = sum(1 for v in groups.values() if len({i.get('folderId') for i in v}) == 1)
print(f"  groupes dont tous les éléments sont dans le même dossier : {same_dir} sur {len(groups)}")
withdom = sum(1 for it in items if cs.bw_host(it))
print(f"Éléments avec une adresse web exploitable : {withdom}")
