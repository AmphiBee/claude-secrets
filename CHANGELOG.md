# Journal des versions

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
