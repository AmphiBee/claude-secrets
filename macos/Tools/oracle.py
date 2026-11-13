#!/usr/bin/python3
"""Oracle du regroupement : le script Python fait foi, Swift doit donner les mêmes groupes.

    Tools/oracle.py          régénère Fixtures/*.json (données fictives, aucune valeur réelle)

Ne lit jamais le trousseau : le script est chargé pour ses fonctions pures seulement.
"""
import importlib.machinery as M, importlib.util as U, json, os, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "macos" / "Fixtures"
os.environ.setdefault("CLAUDE_SECRETS_SERVICE", "zztest-oracle")
sys.path.insert(0, str(pathlib.Path.home() / ".local/share/claude-secrets/shim"))
loader = M.SourceFileLoader("cs", str(ROOT / "claude-secrets"))
cs = U.module_from_spec(U.spec_from_loader("cs", loader))
loader.exec_module(cs)

# Noms et adresses fictifs, choisis pour exercer chaque règle de Taxonomy.
SINGLES = """
APP_ACMEMAIL_COM PREPROD_ACMEMAIL_FR ACMEMAIL_API_KEY ACMEMAIL_WEBHOOK_SECRET
SSO_ALPHA_COM SSO_BRAVO_COM SSO_CHARLIE_COM SSO_DELTA_COM SSO_ECHO_COM
LOGIN_FOXTROT_COM GOLF_COM_TOKEN DOCS_HOTEL_COM DRIVE_HOTEL_COM
INDIA_JULIET_TOKEN INDIA_KILO_TOKEN LIMA_API_KEY
PROD_MIKE_FR STAGING_MIKE_FR DEV_MIKE_FR MIKE_FR
NOVEMBER_CO_UK OSCAR_GOUV_FR PAPA_ASSO_FR
QUEBEC_DB_URL ROMEO_URL SIERRA_ADMIN_TOKEN
TANGO_GITHUB_TOKEN UNIFORM_GITHUB_TOKEN VICTOR_GITHUB_TOKEN
WHISKEY_LOCAL_COM XRAY_DDEV_COM YANKEE_RECETTE_FR
ZULU_TOKEN ZULU_ROOT
SOLO_TOKEN ALONE_KEY
CLOUD_ORBIT_COM CONSOLE_ORBIT_COM ORBIT_IO
MY_PLANET_FR PLANET_DASHBOARD_COM
BETA_RIVER_FR RIVER_BETA_FR
1PASSWORD_LIKE_TOKEN X1PASS_SECRET
ÉTÉ_SOLEIL_FR
""".split()
PAIRS = ["WP_NORTHWIND_FR", "NORTHWIND_SHOP_FR", "SOUTHWIND_FR", "EASTWIND_COM", "PREPROD_WESTWIND_COM",
         "LUNA_STAGING", "LUNA_PROD", "MARS_PROD", "MARS_DEV", "JUPITER_ADMIN"]
AWS = ["AWS_ALPHAPROFILE", "AWS_BETAPROFILE"]
DOMAINS = {
    "APP_ACMEMAIL_COM": "app.acmemail.com", "PREPROD_ACMEMAIL_FR": "preprod.acmemail.fr",
    "DOCS_HOTEL_COM": "docs.hotel.com", "DRIVE_HOTEL_COM": "drive.hotel.com",
    "PROD_MIKE_FR": "prod.mike.fr", "STAGING_MIKE_FR": "staging.mike.fr",
    "NOVEMBER_CO_UK": "www.november.co.uk", "OSCAR_GOUV_FR": "oscar.gouv.fr",
    "PAPA_ASSO_FR": "papa.asso.fr", "WP_NORTHWIND_FR": "wp.northwind.fr",
    "NORTHWIND_SHOP_FR": "shop.northwind.fr", "EASTWIND_COM": "eastwind.com",
    "PREPROD_WESTWIND_COM": "preprod.westwind.eastwind.com", "SOUTHWIND_FR": "southwind.fr",
    "MY_PLANET_FR": "my.planet.fr", "BETA_RIVER_FR": "beta.river.fr",
    "SSO_ALPHA_COM": "sso.alpha.com", "ÉTÉ_SOLEIL_FR": "été-soleil.fr",
    "TANGO_GITHUB_TOKEN": "github.com", "ZULU_TOKEN": "zulu",
}
OVERRIDES = {"SOLO_TOKEN": "Mes outils", "ALONE_KEY": "Mes outils", "ZULU_ROOT": "Zulu perso",
             "LIMA_API_KEY": "  "}


def build(names, pairs, aws, extra_single_items=()):
    items = []
    for n in names:
        items.append((n, f"v-{n}", True))
    for b in pairs:
        items += [(b + "_USER", f"u-{b}", True), (b + "_PASSWORD", f"p-{b}", True)]
    for b in aws:
        items += [(b + "_ACCESS_KEY_ID", f"i-{b}", False), (b + "_SECRET_ACCESS_KEY", f"s-{b}", False)]
    items += list(extra_single_items)
    return items


def expected(items, domains, overrides):
    ents = cs.grouped(items)
    tax = cs.Taxonomy(ents, domains, overrides)
    groups = tax.group(ents)
    return {
        "entries": [[k, b, u, e] for k, b, u, _v, e in ents],
        "groups": [{"id": g["id"], "label": g["label"], "kind": g["kind"], "manual": g["manual"],
                    "members": [e[1] for e in g["members"]]} for g in groups],
        "labels": {e[1]: tax.label_of(e[1]) for e in ents},
        "tones": {g["label"]: cs.tone_index(g["label"]) for g in groups},
    }


def emit(name, items, domains, overrides):
    data = {"items": [{"name": n, "value": v, "exported": e} for n, v, e in items],
            "domains": domains, "overrides": overrides, "expected": expected(items, domains, overrides)}
    (OUT / f"{name}.json").write_text(json.dumps(data, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
    print(name, len(items), "secrets,", len(data["expected"]["groups"]), "groupes")


OUT.mkdir(exist_ok=True)
syn = build(SINGLES, PAIRS, AWS)
emit("synthetic", syn, DOMAINS, OVERRIDES)
emit("synthetic-nodomains", syn, {}, {})

# Le jeu de test de la CLI (tests/vault.json) passé par bw_map / bw_domains.
bw = json.loads((ROOT / "tests/vault.json").read_text())
its = bw["items"]
t_items = [(n, v, e) for n, v, e in cs.bw_map(its)]
emit("bwtests", t_items, cs.bw_domains(its), {})

# Tons : quelques libellés particuliers (accents, espaces, tirets).
tones = ["Mondial Relay", "MONDIALRELAY", "Été", "ÉTÉ", "Zoë-Test", "ß", "", "Ça va", "Akeneo", "AWS"]
(OUT / "tones.json").write_text(json.dumps({t: cs.tone_index(t) for t in tones}, indent=1, ensure_ascii=False,
                                           sort_keys=True) + "\n")

# Écriture : cache du shell (shlex.quote) et import .env (parse_env).
import shlex
quotes = ["abc", "a b", "it's", "", "é✓", "a\nb", "x=y:z/w.v-u_t,s@r%q+p", "$HOME", '"d"', "a;b|c&d", "`x`", "\\", "~", "#c"]
env_text = """# commentaire
FOO=bar
export BAZ="quoted value"
QUX='single quoted'
  SPACED = nope
INDENTED_OK=  trimmed  
EMPTY=
lower=case
1BAD=x
EQ=a=b=c
export  TWO_SPACES=v
QUOTE_MID=ab"cd
ONLYQ="
UNI=é✓
"""
(OUT / "edits.json").write_text(json.dumps({
    "quotes": {q: shlex.quote(q) for q in quotes},
    "env_text": env_text,
    "env_parsed": [[n, v] for n, v in cs.parse_env(env_text)],
}, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
print("edits")

# Bitwarden : traduction éléments → secrets, adresses web (éléments fictifs).
def f(name, value, typ=1): return {"name": name, "value": value, "type": typ}
BW_ITEMS = [
    {"name": "Acme Mail", "login": {"username": "a@x.fr", "password": "pw1", "uris": [{"uri": "https://www.Acme.com/login"}]}, "fields": []},
    {"name": "Solo Token", "login": {"username": "", "password": "tok", "uris": []}, "fields": []},
    {"name": "Hors env", "login": {"password": "p"}, "fields": [f("claude_secrets_export", "Non", 0)]},
    {"name": "Nom forcé", "login": {"password": "p"}, "fields": [f("claude_secrets_name", "mon-nom 1"), f("note", "visible", 0)]},
    {"name": "Champs", "login": {}, "fields": [f("Api Key", "k1"), f("Visible", "v", 0), f("Vide", ""), f("api key", "k2"), f("Api Key", "k3")]},
    {"name": "Note seule", "notes": "  texte secret  ", "login": {}, "fields": []},
    {"name": "Note + champ", "notes": "ignorée", "login": {}, "fields": [f("A", "1")]},
    {"name": "123 chiffres", "login": {"password": "p", "uris": [{"uri": "http://192.168.1.10/x"}]}, "fields": []},
    {"name": "Mobile", "login": {"password": "p", "uris": [{"uri": "androidapp://com.x"}, {"uri": "app.mobile.io"}]}, "fields": []},
    {"name": "Local", "login": {"password": "p", "uris": [{"uri": "http://site.local"}, {"uri": "localhost:8080"}, {"uri": "http://x.test"}]}, "fields": []},
    {"name": "Impots", "login": {"username": "u", "password": "p", "uris": [{"uri": "https://cfspart.impots.gouv.fr/x"}]}, "fields": []},
    {"name": "Été & café", "login": {"password": "p"}, "fields": []},
    {"name": "---", "login": {"password": "p"}, "fields": []},
    # Éléments de même nom : le plus ancien garde le nom simple, les autres un suffixe stable.
    {"id": "a1", "creationDate": "2024-01-01", "name": "Hubspot", "login": {"username": "jean@x.fr", "password": "p1"}, "fields": []},
    {"id": "a2", "creationDate": "2024-02-01", "name": "Hubspot", "login": {"username": "marie@y.fr", "password": "p2"}, "fields": []},
    {"id": "a3", "creationDate": "2024-03-01", "name": "Hubspot", "login": {"password": "p3"}, "fields": []},
    {"id": "z9", "creationDate": "2020-01-01", "name": "Hubspot Marie", "login": {"password": "p4"}, "fields": []},
    {"id": "b1", "creationDate": "2023-01-01", "name": "Shop", "login": {"username": "boss@a.fr", "password": "p"}, "fields": []},
    {"id": "b2", "creationDate": "2023-02-01", "name": "Shop", "login": {"username": "dupont@a.fr", "password": "p"}, "fields": []},
    {"id": "b3", "creationDate": "2023-03-01", "name": "Shop", "login": {"username": "dupont@b.fr", "password": "p"}, "fields": []},
    {"id": "b4", "creationDate": "2023-04-01", "name": "Shop", "login": {"username": "dupont@b.fr", "password": "q"}, "fields": [f("Api Key", "k")]},
    {"id": "c1", "creationDate": "2022-01-01", "name": "Même ordre", "login": {"password": "p"}, "fields": []},
    {"id": "c2", "creationDate": "2022-01-01", "name": "Même ordre", "login": {"password": "q"}, "fields": []},
    {"id": "d1", "creationDate": "2021-01-01", "name": "Sans secret", "login": {"username": "x"}, "fields": []},
    {"id": "d2", "creationDate": "2021-02-01", "name": "Sans secret", "login": {"password": "p"}, "fields": []},
]
(OUT / "bw.json").write_text(json.dumps({
    "items": BW_ITEMS,
    "map": [[n, v, e] for n, v, e in cs.bw_map(BW_ITEMS)],
    "domains": cs.bw_domains(BW_ITEMS),
    "slugs": {t: cs.bw_slug(t) for t in ["a b", "  x--y ", "1abc", "é", "A_b-c", "", "x.y.z", "9"]},
}, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
print("bw")
