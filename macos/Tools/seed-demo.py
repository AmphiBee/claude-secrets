#!/usr/bin/python3
"""Coffre de démonstration FICTIF (~700 secrets) dans un service de trousseau de test.

    CLAUDE_SECRETS_SERVICE=zztest-demo Tools/seed-demo.py     crée / remplace
    CLAUDE_SECRETS_SERVICE=zztest-demo Tools/seed-demo.py rm  supprime

Écrit par le shim Python, donc dans les mêmes conditions que le vrai coffre (dernier écrivain = CLI).
Refuse tout service qui ne commence pas par « zztest- ». À lancer en session graphique.
"""
import os, pathlib, random, sys

service = os.environ.get("CLAUDE_SECRETS_SERVICE", "")
if not service.startswith("zztest-"):
    sys.exit("Refus : définir CLAUDE_SECRETS_SERVICE=zztest-…")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent / "docs/macos/reference"))
import _keychain as k

if sys.argv[1:] == ["rm"]:
    import subprocess
    sys.exit(subprocess.call(["security", "delete-generic-password", "-s", service, "-a", "vault"]))

rnd = random.Random(7)
syl = "ba be bi bo bu ka ke ki ko la le li lo mu na ne ni no pa pe po ra re ri ro sa se si so ta te ti to va ve zo".split()
services = sorted({"".join(rnd.choice(syl) for _ in range(rnd.choice([2, 3]))).upper() for _ in range(140)})[:95]
vault = {}
def put(name, value, export="1", source="local"):
    vault[name] = {"value": value, "export": export, "source": source}
for i, s in enumerate(services):
    tld = rnd.choice(["COM", "FR", "IO", "NET"])
    src = "bitwarden:Démo" if i % 2 else "local"
    put(f"{s}_{tld}_USER", f"user{i}@exemple.fr", source=src)
    put(f"{s}_{tld}_PASSWORD", f"mdp-fictif-{i}-é", source=src)
    put(f"{s}_API_KEY", f"fictif-key-{i}\nligne 2", source=src)
    put(f"{s}_API_TOKEN", f"fictif-token-{i}", export="0" if i % 9 == 0 else "1", source=src)
    if i % 3 == 0:
        for env in ("PREPROD", "PROD", "DEV"):
            put(f"{env}_{s}_FR_USER", f"{env.lower()}@exemple.fr")
            put(f"{env}_{s}_FR_PASSWORD", f"{env}-fictif-{i}")
    if i % 4 == 0:
        put(f"{s}_WEBHOOK_SECRET", f"whsec-fictif-{i}")
put("AWS_DEMOPROFILE_ACCESS_KEY_ID", "AKIAFICTIF", export="0")
put("AWS_DEMOPROFILE_SECRET_ACCESS_KEY", "fictif-secret", export="0")
for i in range(40):
    put(f"ISOLE_{i:02d}_TOKEN", f"fictif-isole-{i}")
k._lock(); k._state["vault"] = vault; k._state["dirty"] = True; k._flush()
print(len(vault), "secrets fictifs écrits dans le service", service)
