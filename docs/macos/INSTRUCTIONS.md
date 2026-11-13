# Claude Secrets pour macOS : instructions de développement

Document de cadrage pour développer **une application macOS native** de Claude Secrets. À lire en entier avant
d'écrire du code. Il est autonome : il résume ce qui existe, ce qui est déjà en place sur le Mac, ce qu'il faut
construire, dans quel ordre, et les décisions encore ouvertes.

## 1. Contexte

Claude Secrets garde les clés API, tokens et mots de passe dans le trousseau chiffré de la session et laisse
Claude Code les **utiliser** sans jamais les **voir** : le shell résout `$NOM_DU_SECRET`, la conversation ne
contient que le nom. Voir `README.md` (principe, modèle de sécurité) et `.impeccable.md` (public, personnalité,
direction « papier & cuivre »).

Sous Linux, l'outil est **un seul fichier Python** (`claude-secrets`, ~3 300 lignes) : une CLI, plus une
application GTK 4 / libadwaita. **Ni GTK ni libsecret n'existent sur macOS**, donc l'application graphique n'y
tourne pas. Ce qui existe déjà sur le Mac :

- la **CLI** fonctionne, grâce à une couche d'adaptation (voir §3) qui stocke le coffre dans le trousseau macOS ;
- la synchronisation **Bitwarden / Vaultwarden** (`bw-setup`, `bw-sync`) fonctionne, via le client `bw` ;
- **il n'y a pas d'application** : le but de ce projet est d'en construire une.

## 2. Objectif

Une application **macOS native**, installable dans `/Applications`, qui offre la même chose que l'application GTK :
ranger des centaines de secrets par service, les retrouver vite, les copier sans les montrer, en ajouter, en
supprimer, synchroniser depuis Bitwarden. Elle **cohabite** avec la CLI (mêmes données, même format) : aucun des
deux ne doit casser l'autre.

Hors périmètre (pour l'instant) : iOS, synchronisation entre Mac par iCloud, remplacement de Bitwarden, support de
Linux par cette base de code.

## 3. Ce qui est déjà en place sur le Mac (ne pas refaire)

| Élément | Où |
|---|---|
| Commande | `~/.local/bin/claude-secrets` (wrapper bash) |
| Script Python (copie du script Linux) | `~/.local/share/claude-secrets/claude-secrets.py` |
| Couche `gi` / `Secret` → trousseau | `~/.local/share/claude-secrets/shim/gi/repository/_keychain.py` (copie dans `docs/macos/reference/`) |
| Cache d'export pour les shells | `$XDG_RUNTIME_DIR/claude-secrets.env`, avec `XDG_RUNTIME_DIR="${TMPDIR%/}"` (défini dans `~/.zshenv`) |
| État de l'application | `~/.config/claude-secrets/state.json` |
| Verrou d'écriture | `~/.config/claude-secrets/.vault.lock` (`flock` exclusif) |
| Client Bitwarden | `bw` (Homebrew `bitwarden-cli`) |
| Disque | FileVault activé (le cache sur disque est donc chiffré au repos) |

### Format du coffre (le contrat à respecter)

**Un seul élément de trousseau** : mot de passe générique (`kSecClassGenericPassword`), service
`claude-secrets-vault`, compte `vault`, trousseau de connexion. Sa donnée est un JSON UTF-8 :

```json
{ "NOM_DU_SECRET": { "value": "…", "export": "1", "source": "local" } }
```

- `export` : `"1"` = exposé en variable d'environnement, `"0"` = jamais exposé (profils AWS, clé de session…).
- `source` : `"local"` ou `"bitwarden:<nom du dossier>"`. Elle **doit être conservée** à la restauration d'une
  suppression annulée (sinon un secret Bitwarden deviendrait local).
- Noms : `^[A-Z][A-Z0-9_]*$`. Les noms qui commencent par `_` sont **réservés** (ex. `_BW_SESSION`, la clé de
  session Bitwarden) : ils n'apparaissent ni dans l'application ni dans la CLI.
- **Verrou** : toute écriture prend un `flock` exclusif sur `~/.config/claude-secrets/.vault.lock`, **relit** le
  coffre après avoir obtenu le verrou, modifie, puis réécrit. Sans cela, deux processus s'écraseraient.
- **Cache du shell** : après toute modification, régénérer `$XDG_RUNTIME_DIR/claude-secrets.env` (lignes
  `export NOM='valeur'` échappées pour le shell, **uniquement** les secrets exportés), créé en `0600` dès
  l'ouverture. Ne jamais le relire s'il appartient à un autre utilisateur ou s'il est lisible par d'autres.
- `state.json` : clés `installed`, `version`, `bitwarden` (`server`, `email`, `folder`, `auto_sync`), `group_by`,
  `domains` (adresses web par secret, issues de Bitwarden), `groups` (groupes forcés à la main). Ces données ne
  sont **pas** des secrets.

### Ce que fait chaque commande de la CLI (référence de parité)

`list`, `get`, `set`, `set-login`, `rm`, `export`, `import` (fichier `.env`), `bw-setup`, `bw-sync [--prune]`,
`bw-logout`, `aws-import`, `aws-credentials`, `doctor`, `version`. La logique est dans `claude-secrets` (lire
`store_*`, `bw_*`, `grouped`, `Taxonomy`, `cli`).

## 4. Fonctionnalités à reproduire

Parité avec l'application GTK, décrite dans `README.md` (§ « L'application », « Regroupement par service »,
« Gros coffres »). Essentiel :

1. **Liste rangée par service** : lettre d'index, monogramme coloré (teinte déduite du nom, la même partout),
   compteur, tampon PROJET / MANUEL, ligne dépliable. Mode « par type » en alternative (clés et tokens,
   identifiants, AWS, hors environnement), choix mémorisé.
2. **Regroupement automatique** : algorithme de `Taxonomy` (extension, environnement, préfixe de page, mots de
   variable ; premier mot partagé par au moins deux entrées ; l'adresse web Bitwarden prime sur le nom). À
   **porter à l'identique**.
3. **Recherche** en mémoire (noms, identifiants, noms de groupe) ; `⏎` copie le premier résultat ; les groupes
   s'ouvrent seuls quand il y a peu de résultats.
4. **Valeurs toujours masquées** (caviardage plein) ; œil pour afficher ; copie avec **effacement du
   presse-papier au bout de 45 s** ; cadenas pour un secret hors environnement.
5. **Nouveau secret** (clé/token ou identifiant + mot de passe), modifier, **supprimer avec « Annuler » pendant
   8 s** (restauration fidèle), **importer un `.env`** collé (« N détectés, dont M remplacés »), **changer de
   groupe**.
6. **Synchronisation Bitwarden** (manuelle, puis automatique) en réutilisant `bw` ; saisie du mot de passe
   maître dans l'application (jamais conservé, seule la clé de session va dans le trousseau).
7. **Profils AWS** : affichage, import, `credential_process`.
8. **Fermer = masquer** : la fenêtre vide sa liste, referme les détails, masque les mots de passe affichés,
   efface la recherche ; elle quitte seule après **20 minutes** masquée.
9. **Gros coffres** : ~700 entrées. Ouverture instantanée, contenu des groupes construit à l'ouverture, recherche
   en mémoire, aucune relecture du trousseau à chaque frappe.

## 5. Exigences de sécurité (non négociables)

- **Jamais de valeur dans** : un journal, une trace, un message d'erreur, une sortie de console, le presse-papier
  sans effacement, un nom de fichier, un argument de commande (visible dans `ps`).
- Les valeurs ne vivent en mémoire **qu'à partir du déverrouillage** et sont relâchées au masquage prolongé.
- Presse-papier : marquer la copie comme **confidentielle** (`org.nspasteboard.ConcealedType`) pour que les
  gestionnaires de presse-papier ne l'archivent pas ; n'effacer que si le contenu est encore le nôtre.
- Appeler `bw` avec le mot de passe maître et la session par **l'environnement du processus**, jamais par argument.
- Verrouillage de l'application : envisager Touch ID (`LocalAuthentication`) avant d'afficher une valeur ou de
  copier. À décider (§9).
- Application **non sandboxée** (elle lance `bw`, lit `~/.config`, écrit dans `$TMPDIR`) mais avec le **hardened
  runtime** et une signature (au minimum ad hoc).
- **Ne jamais travailler contre le vrai coffre.** Une fois `bw-sync` lancé, le trousseau de ce Mac contient les
  vrais secrets. Pendant le développement et les tests : utiliser un service de trousseau de test (§8), des
  noms préfixés `ZZTEST_`, et ne jamais lire ni afficher le vrai coffre. Ne jamais lancer `claude-secrets get` ou
  `export` depuis une session Claude Code.

## 6. Architecture proposée

**Recommandation : SwiftUI, un cœur Swift natif qui lit et écrit le même élément de trousseau.**

- **Stockage** : `Security.framework` (`SecItemCopyMatching` / `SecItemUpdate`) sur l'élément du §3, avec le
  même verrou `flock` et le même cache du shell. Le cœur est une bibliothèque Swift séparée (`SecretsCore`) sans
  dépendance à l'interface, testable seule.
- **Bitwarden** : lancer `bw` (`Process`) ; ne pas réimplémenter son API. Reprendre `bw_map` pour la traduction
  élément → secrets (nom de l'élément ; paire `_USER`/`_PASSWORD` ; champs masqués `NOM_CHAMP` ; champs
  `claude_secrets_name` et `claude_secrets_export`).
- **Regroupement** : porter `Taxonomy` en Swift. Le script Python sert d'**oracle** : produire un fichier JSON
  « entrée → groupe attendu » à partir de `tests/vault.json`, et vérifier que Swift donne les mêmes groupes.
- **Interface** : SwiftUI, fenêtre unique, `NavigationSplitView` ou liste groupée, barre de menus complète,
  raccourcis macOS (§7). Option : une icône dans la barre de menus pour la recherche rapide.
- **Compilation** : ce Mac n'a que les **Command Line Tools** (Swift 6.4, pas Xcode). Prévoir un projet **Swift
  Package Manager** et un script qui assemble le `.app` (Info.plist, icône `.icns`, signature). Xcode complet
  n'est nécessaire que pour les aperçus SwiftUI et la notarisation.

Alternatives écartées : réécrire en Python + PyObjC (aucun gain de « natif », dépendance à Python) ; Electron ou
Tauri (lourd, mauvais fit pour un outil de sécurité) ; embarquer GTK sur macOS (apparence non native, contraire à
l'objectif).

### Point technique à valider en premier (spike)

Le coffre a été écrit par le processus `/usr/bin/python3`, donc l'**ACL** de l'élément ne fait confiance qu'à
Python. Une application Swift qui le lira provoquera **une demande d'autorisation** du trousseau. À vérifier :
(a) ce que macOS affiche et si « Toujours autoriser » suffit durablement, y compris après une mise à jour de
l'application ; (b) si l'application doit recréer l'élément avec une ACL qui inclut à la fois l'app et
`/usr/bin/python3` (la CLI doit continuer à fonctionner sans demande) ; (c) le temps de lecture du coffre sur
~700 entrées. Si l'ACL pose problème, repli : l'application délègue le stockage à la CLI via un sous-processus.

## 7. Direction de design

Reprendre `.impeccable.md` : **papier & cuivre**, clair **et** sombre, cuivre `#F6A974 → #DE7650 → #B9573A →
#8E3E28` (étincelle `#FFF4D2`) employé comme un **tampon** (sceau, état actif, action principale), jamais comme
décor. Voix en français, tutoiement, phrases courtes.

Adaptations pour macOS :

- **Typographie** : Gelasio n'existe pas sur macOS ; utiliser le serif système **New York** (ou Georgia en repli)
  pour les titres, SF pour le corps. Toujours prévoir un repli.
- **Natif d'abord** : barre de menus, `⌘N` nouveau, `⌘F` rechercher, `⌘W` masquer la fenêtre, `⌘Q` quitter, `⌘,`
  réglages ; respecter « Réduire les animations » et le thème du système ; contraste WCAG AA dans les deux thèmes.
- **Anti-références** : l'aspect « SaaS bleu-violet », le néon, le texte en dégradé, le glassmorphism décoratif,
  les grilles de cartes identiques. Listes à angles droits et filets fins ; seul arrondi : le monogramme.
- L'état « masqué / affiché / hors environnement » ne repose jamais sur la couleur seule.
- Une seule entrée orchestrée (sceau de l'en-tête, apparition échelonnée des lignes), décélération
  exponentielle, jamais de rebond.

## 8. Tests

- Reprendre l'esprit de `tests/run.py` : suites `core`, `bitwarden` (avec `tests/fake-bw`, hors ligne), et une
  suite interface.
- **Service de trousseau de test** : le service est aujourd'hui codé en dur (`claude-secrets-vault`). Ajouter une
  surcharge par variable d'environnement (par exemple `CLAUDE_SECRETS_SERVICE`) **dans la CLI et dans la couche
  d'adaptation**, et l'utiliser dans tous les tests, pour ne jamais toucher le vrai coffre.
- Tests de régression du **format** : un coffre écrit par Python doit être relu à l'identique par Swift, et
  inversement (y compris `source` et `export`, valeurs multi-lignes et Unicode).
- Test de **concurrence** : deux écrivains simultanés (CLI et application) sans perte de mise à jour.
- **Tester le trousseau en SSH est impossible** (il est verrouillé, erreur 36). Lancer les tests dans une session
  graphique : Terminal sur le Mac, ou un LaunchAgent éphémère (exemple : `docs/macos/reference/gui-run.sh`).

## 9. Décisions encore ouvertes

1. **Moteur** : cœur Swift natif (recommandé) ou application qui délègue tout à la CLI par sous-processus (plus
   rapide à livrer, mais dépend de Python et du script) ?
2. **Touch ID** avant d'afficher ou de copier une valeur : oui, non, ou réglable ?
3. **Icône dans la barre de menus** (recherche rapide sans ouvrir la fenêtre) : oui ou non ?
4. **Version minimale de macOS** visée (le Mac de développement est en macOS 27).
5. **Distribution** : usage personnel (signature ad hoc) ou diffusion (compte Apple Developer, notarisation) ?
6. **Où vit le code** : dans ce dépôt (dossier `macos/`, branche `macos-native`) ou dans un dépôt séparé ?

## 10. Plan de travail

0. **Spike** (une session) : lecture de l'élément depuis Swift, comportement de l'ACL, temps de lecture, fluidité
   d'une liste SwiftUI de 700 lignes avec dépliage. Livrable : une note de résultats et la décision §9.1.
1. **Lecture seule** : liste par service, monogrammes, recherche, valeurs masquées, copie avec effacement 45 s,
   « fermer = masquer ».
2. **Écriture** : nouveau secret, modification, suppression avec annulation 8 s, import `.env`, changer de groupe,
   verrou et cache du shell.
3. **Bitwarden et AWS** : `bw-setup` / `bw-sync` dans l'application, synchronisation automatique, profils AWS.
4. **Finition** : design complet clair et sombre, animations, réglages, icône `.icns`, script d'assemblage et de
   signature du `.app`, tests, section macOS dans `README.md`, entrée dans `CHANGELOG.md`.

Critère de fin de chaque étape : tests verts, parité vérifiée contre la CLI sur un coffre de test, aucune valeur
visible dans les journaux.

## 11. Règles de travail pour cette session

- Travailler sur la branche `macos-native` ; **ne rien pousser** sans demande explicite (le dépôt est public).
- Ne jamais écrire de nom de secret réel, d'adresse de serveur ou d'identifiant personnel dans le code, les tests,
  la documentation ou les messages de commit : ce dépôt est public. Utiliser des données fictives.
- Une étape à la fois ; relire le critère de fin avant de passer à la suivante.
