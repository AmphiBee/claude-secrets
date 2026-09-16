# Claude Secrets

Gérez vos clés API, tokens et mots de passe dans le trousseau chiffré de votre
session, et laissez Claude Code les **utiliser** sans jamais les **voir**.

> Projet indépendant développé par [AmphiBee](https://amphibee.fr).
> Non affilié à Anthropic.

---

## Le problème

Faire travailler un assistant IA sur vos projets suppose souvent de lui donner
accès à des services authentifiés. Coller une clé API dans un prompt la fait
entrer dans l'historique de conversation, où elle est conservée en clair.

## L'approche

Le secret est résolu par **le shell**, pas par le modèle.

```bash
curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" https://api.cloudflare.com/...
```

Bash substitue la valeur au moment de l'exécution. Elle part dans la requête
réseau, mais la conversation ne contient que `$CLOUDFLARE_API_TOKEN`.

C'est la différence entre « Claude *utilise* le secret » et « Claude *connaît*
le secret ». Seul le second pose problème.

## Ce que fait Claude Secrets

- Stocke vos secrets **chiffrés** dans le trousseau de session (GNOME Keyring,
  KWallet — toute implémentation du Secret Service freedesktop)
- Les expose comme variables d'environnement dans chaque shell
- **Aucun mot de passe à retaper** : le trousseau est déverrouillé par votre
  mot de passe de session
- Installe les règles qui empêchent Claude Code d'afficher une valeur par
  accident (`echo`, `printenv`, lecture des `.env`…)
- Interface graphique GTK 4 native, et une CLI pour les scripts

![Aucune capture pour l'instant](#)

---

## Installation

```bash
git clone https://github.com/AmphiBee/claude-secrets.git
cd claude-secrets
./install.sh
```

Puis **ouvrez un nouveau terminal**.

L'installateur vérifie les dépendances et propose de les installer si besoin —
c'est la seule étape qui demande `sudo`. Tout le reste se passe dans votre
dossier personnel.

### Dépendances

| Distribution | Paquets |
|---|---|
| Debian / Ubuntu / Zorin | `python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 gir1.2-secret-1 gnome-keyring` |
| Fedora | `python3-gobject gtk4 libadwaita libsecret gnome-keyring` |
| Arch | `python-gobject gtk4 libadwaita libsecret gnome-keyring` |

Linux avec session graphique uniquement. Ne fonctionne pas en SSH sans session
ouverte (le trousseau n'est alors pas déverrouillé).

---

## Utilisation

### Interface graphique

Lancez **Claude Secrets** depuis le menu des applications, ou `claude-secrets`.

Au premier lancement, l'application propose de déployer sa configuration et
affiche exactement ce qui sera modifié.

### Ligne de commande

```bash
claude-secrets                      # interface graphique
claude-secrets list                 # noms des secrets (jamais les valeurs)
claude-secrets set NOM              # ajouter une clé (saisie masquée)
claude-secrets set-login NOM        # ajouter un identifiant + mot de passe
claude-secrets rm NOM               # supprimer
claude-secrets doctor               # vérifier l'installation
claude-secrets install              # (re)déployer la configuration
claude-secrets import fichier.env   # importer depuis un .env existant
```

### Deux types d'entrées

**Clé ou token** — une valeur, une variable :

```
CLOUDFLARE_API_TOKEN  →  $CLOUDFLARE_API_TOKEN
```

**Identifiant + mot de passe** — un nom de base, deux variables :

```
CLIENTX_WP  →  $CLIENTX_WP_USER  et  $CLIENTX_WP_PASSWORD
```

```bash
curl -u "$CLIENTX_WP_USER:$CLIENTX_WP_PASSWORD" https://client-x.fr/wp-json/wp/v2/posts
```

### Identifiants AWS

Les clés AWS sont un cas à part : en faire des variables d'environnement
écraserait globalement le profil par défaut et rendrait `--profile`
imprévisible. Claude Secrets les stocke donc **hors environnement** et les sert
à la demande via `credential_process`, compris nativement par l'AWS CLI, les
SDK et Terraform.

```bash
claude-secrets aws-import              # importe les profils dans le trousseau
claude-secrets aws-import --activate   # + bascule ~/.aws/config dessus
```

L'activation écrit une ligne `credential_process` par profil dans
`~/.aws/config`, puis renomme `~/.aws/credentials` en `credentials.disabled`
(ce fichier est prioritaire, il doit être écarté). Les deux fichiers sont
sauvegardés avant modification.

```bash
aws sts get-caller-identity --profile amphibee   # vérification
```

Pour revenir en arrière : restaurez `credentials.disabled` et retirez les
lignes `credential_process` de `~/.aws/config`.

### Au quotidien avec Claude Code

Demandez simplement : « utilise le token Cloudflare pour lister mes zones ».
Claude connaît les noms disponibles via `claude-secrets list` et écrit la
commande avec `$CLOUDFLARE_API_TOKEN`.

Un secret ajouté **pendant** une session n'est pas dans l'environnement figé au
démarrage. Claude sait recharger le cache :

```bash
source "$XDG_RUNTIME_DIR/claude-secrets.env" && <votre commande>
```

---

## Ce qui est déployé

`claude-secrets install` écrit cinq choses, toutes dans votre dossier
personnel, encadrées par des marqueurs pour rester réversibles :

| Élément | Emplacement |
|---|---|
| Commande `claude-secrets` | `~/.local/bin/` |
| Chargement des secrets + PATH | `~/.zshrc` ou `~/.bashrc` |
| Règles de manipulation | `~/.claude/CLAUDE.md` |
| Garde-fous anti-fuite | `~/.claude/settings.json` |
| Lanceur d'application | `~/.local/share/applications/` |

L'opération est **idempotente** : la relancer ne duplique rien. Les fichiers
existants sont sauvegardés (`.bak-<horodatage>`) et leur contenu préservé —
le bloc est ajouté à côté, jamais à la place.

## Modèle de sécurité

**Ce qui est protégé.** Les secrets sont chiffrés au repos par le trousseau.
Pendant la session, un cache existe dans `$XDG_RUNTIME_DIR`, qui est un système
de fichiers **en mémoire vive** : rien n'atteint le disque, tout disparaît à
l'extinction. Les valeurs n'entrent jamais dans l'historique de conversation
tant que les règles installées sont respectées.

**Ce qui ne l'est pas.** Toute application lancée sous votre compte peut lire
le trousseau une fois la session ouverte — c'est le modèle du Secret Service,
pas une faiblesse de cet outil. Les secrets sont dans l'environnement de vos
shells : un programme que vous lancez peut donc les lire. Cet outil protège
contre la fuite dans les prompts et les transcriptions, pas contre un logiciel
malveillant déjà en place.

**Si un secret a fuité** dans une conversation, révoquez-le et régénérez-le.
C'est la seule réponse fiable.

## Désinstallation

```bash
./uninstall.sh
```

Retire l'intégration et la commande. **Les secrets restent dans le trousseau** ;
pour les effacer aussi, ouvrez « Mots de passe et clés » (seahorse) et
supprimez les entrées `Claude Secrets — …`.

## Licence

MIT — voir [LICENSE](LICENSE).
