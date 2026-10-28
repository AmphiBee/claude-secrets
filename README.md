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

Les secrets sont rangés par section : clés et tokens, identifiants, profils AWS
et secrets hors environnement. Les actions courantes (afficher, copier) sont
directement sur chaque ligne ; modifier et supprimer sont dans le menu ⋮.

| Raccourci | Action |
|---|---|
| `Ctrl+N` | Nouveau secret |
| `Ctrl+F` | Rechercher (ou tapez directement) |
| `Échap` | Fermer la recherche |

### Ligne de commande

```bash
claude-secrets                      # interface graphique
claude-secrets list                 # noms des secrets (jamais les valeurs)
claude-secrets set NOM              # ajouter une clé (saisie masquée)
claude-secrets set-login NOM        # ajouter un identifiant + mot de passe
claude-secrets rm NOM               # supprimer
claude-secrets doctor               # vérifier l'installation
claude-secrets version              # version installée
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

### Synchroniser depuis Bitwarden

Vos secrets peuvent venir d'un coffre Bitwarden — le service officiel comme une
instance auto-hébergée (Vaultwarden compris). La synchronisation va **dans un
seul sens**, du coffre vers le trousseau : rien n'est jamais renvoyé vers
Bitwarden.

Prérequis : le CLI Bitwarden.

```bash
npm install -g @bitwarden/cli     # ou : sudo snap install bw
```

Première connexion, dans un terminal (elle peut demander un code à deux
facteurs) :

```bash
claude-secrets bw-setup
```

Elle demande l'URL du serveur (vide pour bitwarden.com), l'adresse e-mail, le
mot de passe maître, puis le dossier à synchroniser.

```bash
claude-secrets bw-sync            # synchroniser
claude-secrets bw-sync --prune    # + supprimer localement ce qui a quitté le coffre
claude-secrets bw-lock            # oublier la session
claude-secrets bw-logout          # déconnecter le compte (pour changer de serveur)
```

Si un compte est déjà connecté, `bw-setup` le détecte et ne redemande que le
mot de passe maître : le CLI Bitwarden refuse de changer de serveur tant qu'une
session existe. Pour basculer vers un autre serveur ou un autre compte, passez
d'abord par `claude-secrets bw-logout`.

La synchronisation est aussi accessible depuis le menu de l'application.

### Synchronisation automatique

Une fois le compte configuré, l'application synchronise le dossier toute seule :
au lancement, puis à la réouverture de la fenêtre, au plus une fois toutes les
10 minutes. Elle travaille en arrière-plan et n'affiche une notification que si
quelque chose a changé.

Elle est volontairement prudente :

- elle **ne demande jamais le mot de passe maître** d'elle-même : si le coffre
  est verrouillé, une notification propose de le déverrouiller ;
- elle **ne supprime jamais rien** (l'équivalent de `bw-sync` sans `--prune`) ;
- une erreur n'est signalée qu'une fois par session.

On la désactive avec la case « Synchroniser automatiquement » du menu principal.

#### Serveur auto-hébergé plus ancien que le CLI

Les versions récentes du CLI Bitwarden lancent, juste après l'authentification,
une étape de migration que les serveurs auto-hébergés n'implémentent pas
toujours. La connexion réussit, puis le CLI affiche une erreur
(`key_id_backfill`, `Encrypted Migrator`, HTTP 404) et s'arrête en échec.

Claude Secrets le détecte, à la connexion comme au déverrouillage : si la
session est bien ouverte, l'opération continue. Si vous préférez supprimer l'erreur à la source, alignez le CLI sur
la version de votre serveur :

```bash
# version du serveur :
curl -s https://vault.exemple.fr/api/config | head -c 60
npm install -g @bitwarden/cli@2026.6.0    # la même version
```

#### Le mot de passe maître

Le CLI Bitwarden fonctionne en deux temps : la connexion, puis le
**déverrouillage**, qui exige le mot de passe maître et renvoie une clé de
session. Une clé d'API Bitwarden ne dispense pas du déverrouillage.

Claude Secrets ne conserve **jamais** le mot de passe maître. Il garde la clé
de session, chiffrée dans le trousseau, et la réutilise pour les
synchronisations suivantes. Quand elle n'est plus valable, le mot de passe est
redemandé. `claude-secrets bw-lock` ou `bw lock` la révoque immédiatement.

#### Ce qui est importé

Seuls les éléments du dossier choisi sont lus. Le nom de l'élément devient le
nom de la variable (`Cloudflare API` → `CLOUDFLARE_API`).

| Dans Bitwarden | Devient |
|---|---|
| Identifiant avec mot de passe seul | `NOM` |
| Identifiant avec nom d'utilisateur + mot de passe | `NOM_USER` et `NOM_PASSWORD` |
| Champ personnalisé **masqué** | `NOM_CHAMP` |
| Champ personnalisé visible | ignoré |

Deux champs personnalisés pilotent l'import :

- `claude_secrets_name` — impose le nom de la variable plutôt que de le déduire
- `claude_secrets_export` à `false` — le secret est stocké mais **jamais**
  exposé dans l'environnement

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

## Mise à jour

```bash
cd claude-secrets
git pull
./install.sh
```

ou, équivalent : `make update`.

L'installateur est idempotent : il remplace la commande, redéploie la
configuration sans dupliquer quoi que ce soit, et affiche l'ancienne et la
nouvelle version.

```
✓ Mise à jour depuis Claude Secrets 1.0.0 → Claude Secrets 1.1.0
```

**Vos secrets ne sont jamais touchés** par une mise à jour : ils vivent dans le
trousseau, pas dans les fichiers du projet.

Après une mise à jour, deux gestes :

- **fermez et relancez l'application** si elle était ouverte (elle tourne sur
  l'ancien code tant qu'elle n'est pas redémarrée) ;
- **ouvrez un nouveau terminal** pour recharger l'environnement.

### Savoir si vous êtes à jour

```bash
claude-secrets version    # version installée
claude-secrets doctor     # état complet
```

Lancé depuis le dépôt, `doctor` compare la copie du dépôt à celle installée et
signale un décalage :

```
La version installée diffère de celle de ce dépôt.
Mets à jour avec :  ./install.sh
```

Le [journal des versions](CHANGELOG.md) liste les changements.

## Ce qui est déployé

`claude-secrets install` écrit six choses, toutes dans votre dossier
personnel, encadrées par des marqueurs pour rester réversibles :

| Élément | Emplacement |
|---|---|
| Commande `claude-secrets` | `~/.local/bin/` |
| Chargement des secrets + PATH | `~/.zshrc` ou `~/.bashrc` |
| Règles de manipulation | `~/.claude/CLAUDE.md` |
| Garde-fous anti-fuite | `~/.claude/settings.json` |
| Lanceur d'application | `~/.local/share/applications/` |
| Icône | `~/.local/share/icons/hicolor/` |

L'opération est **idempotente** : la relancer ne duplique rien. Les fichiers
existants sont sauvegardés (`.bak-<horodatage>`) et leur contenu préservé —
le bloc est ajouté à côté, jamais à la place.

## Tests

```bash
make test                      # tout
/usr/bin/python3 tests/run.py core        # logique et stockage
/usr/bin/python3 tests/run.py bitwarden   # synchronisation (faux CLI, hors ligne)
/usr/bin/python3 tests/run.py gui         # interface (session graphique requise)
```

Les tests écrivent dans le trousseau des secrets préfixés `ZZTEST_`, supprimés
à la fin, et n'utilisent ni compte ni serveur Bitwarden réels : un faux CLI
(`tests/fake-bw`) simule le coffre. La configuration de l'utilisateur est
sauvegardée puis restaurée.

## Regroupement par service

La liste peut être regroupée **par service** (menu principal → « Grouper par
service », le réglage est mémorisé) ou **par type** (clés, identifiants, AWS,
hors environnement).

Le classement est automatique et se déduit des noms : rien à configurer, et une
nouvelle entrée est rangée toute seule. Les noms viennent le plus souvent des
sites de Bitwarden (`APP_HUBSPOT_COM` est `app.hubspot.com`), alors on écarte ce
qui n'identifie pas le service :

- l'extension (`COM`, `FR`, `NET`…) ;
- l'environnement (`PROD`, `PREPROD`, `LOCAL`, `DOCKER`, `DDEV`…) ;
- le préfixe qui décrit la page (`APP`, `LOGIN`, `ID`, `WP`, `PMA`…), y compris
  ceux que la liste ne connaît pas : un premier mot suivi de nombreux sites
  différents est reconnu comme tel ;
- les mots de variable (`API`, `KEY`, `TOKEN`, `PASSWORD`…), qui ne désignent
  jamais un service.

On retient alors le premier mot partagé par au moins deux entrées. Ainsi
`MEO_FR`, `PMA_MEO_DOCKER` et `MEO_PREPROD_AMPHIBEE_FR` forment le groupe
« Meo ». Un environnement dans le nom marque le groupe comme **projet**. Les
entrées sans voisin tombent dans « Autres sites » (avec un nom de domaine) ou
« Autres clés et accès ».

**Quand l'entrée vient de Bitwarden, l'adresse web de l'élément prime sur le
nom.** La synchronisation retient le site (`app.hubspot.com`) de chaque élément ;
c'est lui qui désigne le service, même si l'élément s'appelle « Mon CRM ». Deux
garde-fous évitent les faux regroupements :

- les sous-domaines d'un même service ne l'éclatent pas (`docs.google.com` et
  `drive.google.com` restent dans « Google ») ;
- un sous-domaine n'est un projet à part que s'il existe aussi ailleurs dans le
  coffre : `preprod.ecranlarge.amphibee.fr` va dans « Ecranlarge », pas chez
  l'hébergeur « Amphibee ».

Les adresses locales (`localhost`, IP) et les applications mobiles sont
ignorées. Ces adresses ne sont pas des secrets : elles sont conservées dans
`~/.config/claude-secrets/state.json` (clé `domains`), pas dans le trousseau, et
seules celles des secrets qui existent encore sont gardées. Elles apparaissent à
la première synchronisation après la mise à jour ; d'ici là, le classement se
fait sur les noms.

Chaque service est une ligne dépliable dont le contenu n'est construit qu'à
l'ouverture : l'affichage reste instantané, même avec des centaines de secrets.
Pendant une recherche qui donne peu de résultats, les groupes s'ouvrent seuls.

## Gros coffres

Avec plusieurs centaines de secrets, la lecture du trousseau prend quelques
secondes : chaque entrée est déchiffrée individuellement. L'application en tient
compte — la fenêtre s'ouvre immédiatement, la liste s'affiche d'abord depuis le
cache du shell (déjà en RAM) pendant que le trousseau est relu en arrière-plan,
elle s'affiche par lots et la recherche travaille en mémoire sans jamais
relire le trousseau.

Fermer la fenêtre la masque sans quitter l'application : la réouvrir est
instantané. Elle quitte seule après 20 minutes de masquage ; `Ctrl+Q` la
quitte tout de suite.

Au-delà de 75 entrées, seules les premières sont affichées, avec un bouton
« Tout afficher ». **La recherche porte toujours sur l'ensemble des secrets**,
affichés ou non.

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
