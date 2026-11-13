# Claude Secrets : développement de l'application macOS

Lis d'abord **`docs/macos/INSTRUCTIONS.md`** : il cadre tout (contexte, format du coffre, parité à atteindre,
sécurité, architecture, plan par étapes, décisions ouvertes).

Rappels :
- Branche de travail : `macos-native`. Ne rien pousser sans demande explicite : le dépôt est **public**.
- **Ne jamais lire, afficher ni modifier le vrai coffre** de ce Mac (`claude-secrets get` / `export` sont interdits).
  Tests : service de trousseau de test et noms `ZZTEST_` uniquement.
- Aucune valeur de secret dans un journal, un message d'erreur, un argument de commande ou la conversation.
- Aucun nom de secret réel, serveur ou identifiant personnel dans le code, les docs ou les commits.
- Le trousseau est verrouillé en SSH : tester en session graphique (Terminal ou `docs/macos/reference/gui-run.sh`).
- Commence par l'étape 0 du plan (spike) et la décision « moteur » du §9 : demande-la à l'utilisateur.
