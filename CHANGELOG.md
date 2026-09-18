# Journal des versions

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
