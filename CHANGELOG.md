# Journal des versions

## 1.7.1

Rapidité.

- Ouverture : la liste s'affiche d'abord depuis le cache du shell (en RAM,
  `0600`, relu en ≈ 70 ms pour 700 secrets), pendant que le trousseau est relu
  derrière ; la lecture complète apporte ensuite ce qui n'est pas exporté (AWS,
  secrets hors environnement) et répare le cache s'il était périmé. Un cache
  absent, lisible par d'autres, altéré ou vide est ignoré : on retombe sur la
  lecture habituelle. Le sous-titre indique « lecture du trousseau… » tant
  qu'elle n'est pas finie.
- Synchronisation Bitwarden : elle relisait le trousseau trois fois (au départ,
  pour le cache, puis pour l'interface). Elle ne le lit plus qu'une fois,
  n'écrit le cache que si quelque chose a changé, et l'interface n'applique que
  ce que la synchro a changé : une modification faite pendant ce temps n'est
  plus écrasée.

## 1.7.0

- Synchronisation Bitwarden automatique : au lancement, puis à la réouverture
  de la fenêtre (au plus toutes les 10 minutes), en arrière-plan. Une
  notification n'apparaît que si quelque chose a changé.
- Prudente par construction : elle ne demande jamais le mot de passe maître
  (coffre verrouillé → notification « Déverrouiller »), ne supprime jamais rien
  (pas de `--prune`), ne tourne jamais deux fois en même temps, et ne signale
  une erreur qu'une fois par session.
- Case « Synchroniser automatiquement » dans le menu principal (activée par
  défaut dès qu'un compte est configuré) ; la réactiver relance une synchro.
- Tests : la suite `gui` utilise désormais un état isolé et le faux CLI, pour
  qu'une synchro automatique ne touche jamais au vrai compte.

## 1.6.0

- Fermer la fenêtre (croix ou Ctrl+W) la masque au lieu de quitter. Relancer
  l'application la réaffiche en ≈ 65 ms, liste comprise en ≈ 0,3 s, au lieu
  des ≈ 2 s de lecture du trousseau. Le trousseau est relu en silence derrière,
  et la liste n'est reconstruite que si quelque chose a changé.
- Garde-fous : en se masquant, la fenêtre vide sa liste, referme les détails,
  masque les mots de passe affichés et efface la recherche. Si elle reste
  masquée 20 minutes, l'application quitte seule.
- Quitter vraiment : Ctrl+Q, ou « Quitter » dans le menu principal.
- `install.sh` arrête l'instance en cours avant de remplacer la commande, pour
  ne pas continuer à faire tourner l'ancienne version après une mise à jour.

## 1.5.1

- Rapidité : enregistrer, supprimer, annuler une suppression ou importer un
  `.env` figeait la fenêtre environ 2 s, car l'application relisait tout le
  trousseau (700 entrées) deux fois. Elle met désormais à jour ses données en
  mémoire et le cache du shell directement : ≈ 3 ms.
- Sécurité : le cache du shell (`$XDG_RUNTIME_DIR/claude-secrets.env`) est créé
  en `0600` dès l'ouverture. Avant, il restait lisible selon l'umask pendant
  l'écriture, avant le `chmod`.
- Corrige `Entrée` dans la recherche : tapée juste après une frappe, elle
  copiait le premier résultat de la requête précédente.

## 1.5.0

Ergonomie.

- Supprimer un secret ne demande plus de confirmation : un toast propose
  « Annuler » pendant 8 s. La restauration conserve l'origine (Bitwarden ou
  local). Les profils AWS gardent leur confirmation, à cause de la ligne
  `credential_process` à retirer à la main.
- Menu ⋯ : « Copier le nom de la variable » (`$NOM`, ou `$NOM_USER $NOM_PASSWORD`).
- Recherche : `Entrée` copie le premier résultat, `↓` passe à la liste.
- « Importer un .env… » : colle un fichier entier pour créer tous ses secrets
  d'un coup (la CLI `import` partage le même analyseur).
- Après un enregistrement ou un import, le toast rappelle que le secret est
  disponible dans les nouveaux terminaux et copie la commande `source` pour
  celui qui est déjà ouvert.

## 1.4.4

- Corrige : l'application plantait (segfault) en ouvrant le menu d'actions
  (icône ⋯) d'un secret, depuis la 1.4.1. Le menu est toujours construit à la
  demande, mais sans se désenregistrer pendant son propre appel.

## 1.4.3

- Le déverrouillage subit la même limite que la connexion sur un serveur
  auto-hébergé plus ancien que le CLI : la session s'ouvre, puis la migration
  de clés échoue et la commande sort en erreur. La clé de session est
  désormais récupérée et vérifiée avant de conclure à un mot de passe refusé ;
  sinon le message indique comment aligner les versions.

## 1.4.2

- Corrige : chaque installation réécrivait le fichier d'état en entier et
  effaçait donc la configuration Bitwarden (serveur, compte, dossier). Une
  mise à jour obligeait à refaire `bw-setup`.

## 1.4.1

- **Important** : `--prune` ne supprimait pas seulement les secrets du dossier
  synchronisé, mais tout secret d'origine Bitwarden absent de ce dossier.
  Synchroniser un second dossier avec `--prune` effaçait donc le premier.
  L'origine retient désormais le dossier, et `--prune` refuse un dossier vide.
- Suite de tests dans `tests/` (`make test`) : logique, stockage,
  synchronisation sur un faux CLI, et interface

## 1.4.0

Affichage et recherche repensés pour les gros coffres (plusieurs centaines de
secrets) : l'affichage passait de 21 s à moins de 0,3 s, et la recherche de
20 s par frappe à environ 0,2 s.

- La valeur des secrets est lue en mémoire plutôt que par un appel D-Bus par
  secret
- La lecture du trousseau se fait en arrière-plan, fenêtre utilisable aussitôt
- Les données restent en mémoire : la recherche ne relit plus le trousseau, et
  elle est temporisée le temps de la frappe
- Le détail d'une entrée n'est construit qu'au dépliage, et le menu ⋮ qu'à son
  ouverture
- La liste s'affiche par lots, plafonnée à 75 entrées avec « Tout afficher »

## 1.3.2

- Corrige : `bw-setup` échouait avec « Logout required before server config
  update » quand un compte était déjà connecté. La configuration détecte
  maintenant la session en cours et ne redemande que le mot de passe maître.
- Changer de serveur alors qu'un compte est connecté donne un message clair
- Nouvelle commande `bw-logout`

## 1.3.1

- Corrige : une URL de serveur saisie sans `https://` était utilisée telle quelle
- Corrige : sur un serveur auto-hébergé plus ancien que le CLI, la connexion
  réussissait mais l'étape de migration suivante la faisait passer pour un
  échec. L'état réel du compte est désormais vérifié, et le message d'erreur
  explique comment aligner les versions.

## 1.3.0

- Synchronisation depuis Bitwarden (service officiel, instance auto-hébergée et
  Vaultwarden) : `bw-setup`, `bw-sync`, `bw-lock`, et une entrée dans le menu
- Le mot de passe maître n'est jamais conservé ; seule la clé de session l'est,
  chiffrée dans le trousseau, et le déverrouillage est redemandé si elle expire
- Import du dossier Bitwarden choisi, avec champs `claude_secrets_name` et
  `claude_secrets_export`
- `--prune` supprime localement les secrets retirés du coffre
- Les secrets retiennent leur origine ; les entrées réservées à l'outil sont
  masquées dans l'app et la CLI

## 1.2.0

- Nouvelle icône d'application
- Interface repensée : entrées rangées par section (clés et tokens,
  identifiants, AWS, hors environnement), pastille colorée par service, actions
  secondaires regroupées dans un menu, bandeau récapitulatif
- Recherche qui s'ouvre dès qu'on tape, raccourcis clavier (Ctrl+N, Ctrl+F),
  fenêtre « À propos »
- Profils AWS affichés comme une seule entrée, avec la commande à utiliser
- Valeurs masquées sur une longueur fixe, qui ne trahit plus la taille du secret
- Correction : modifier un secret hors environnement le rendait exporté

## 1.1.1

- Correction : afficher ou masquer le mot de passe d'une entrée identifiant +
  mot de passe repliait la ligne. L'affichage est désormais mis à jour sur
  place, et les lignes dépliées le restent après une modification.

## 1.1.0

- Identifiants AWS servis via `credential_process` : les clés restent dans le
  trousseau et ne deviennent jamais des variables d'environnement
  (`aws-import`, `aws-credentials`)
- Notion de secret **non exporté** : conservé chiffré, hors environnement
- Couples identifiant + mot de passe (`set-login`, entrées dépliables)
- `version` et détection d'une version installée obsolète dans `doctor`
- Écriture idempotente : un nom est purgé avant réécriture, plus de doublons

## 1.0.0

- Stockage des secrets dans le trousseau de session (Secret Service)
- Interface GTK 4 / libadwaita, CLI complète
- Installateur idempotent et réversible, entièrement dans le dossier personnel
- Règles `CLAUDE.md` et garde-fous `settings.json` contre l'affichage accidentel
