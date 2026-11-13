# Étape 0 : résultats du spike (service de test `zztest-spike`, 13/11/2026)

Environnement : macOS 27, Swift 6.4.2 (Command Line Tools), session graphique via `reference/gui-run.sh`.
Seul un service de test a été touché ; le vrai coffre n'a jamais été lu.

| Cas | Résultat |
|---|---|
| Swift lit un élément créé par Swift (700 entrées, 58 Ko) | OK, **~11 ms** |
| Python (shim) lit l'élément créé par Swift | OK, **~6 s** |
| Swift lit un élément créé par Python (1 entrée) | OK, **~7,3 s**, pas d'erreur |
| Python relit son propre élément (700 entrées) | OK, **~4,9 s** |

Constats :
- Le format est relu sans erreur dans les deux sens (aucune comparaison valeur par valeur encore).
- Toute lecture **inter-processus** ou par le shim Python coûte plusieurs secondes (évaluation d'ACL
  / API `SecKeychain*` héritée ?) ; une lecture par le même binaire Swift est instantanée.
  La cause exacte reste à isoler (le binaire de test n'est pas signé).
- Aucune boîte de dialogue observable depuis le LaunchAgent : à revérifier à la main dans un Terminal.

## Tours suivants (isolement de la lenteur)

- Appeler le trousseau pour un service absent : 4 ms. Le coût n'est donc pas celui de l'API elle-même.
- Un lecteur dont l'identité n'est **pas celle du dernier écrivain** paie 2 à 7 s **à chaque lecture**, même dans
  le même processus ; l'identité qui a écrit en dernier lit en 11-16 ms.
- Re-signer le binaire (ad hoc) change son identité : il ne peut plus supprimer l'élément (`-25244`) et relit
  en ~4-5 s. Prévoir : une signature **stable** entre deux versions, sinon l'ACL se perd à chaque mise à jour.
- Une ACL créée par Swift (`SecAccess` avec l'app **et** `/usr/bin/python3`) n'a **pas** supprimé la lenteur
  côté Python (6,5 s). Donc « ajouter python à l'ACL » ne suffit pas.
- Aucune boîte de dialogue visible depuis le LaunchAgent : l'attente ressemble à une demande d'autorisation
  qui expire sans réponse. À confirmer à la main.

## Tour 3 (confirmé en Terminal réel : Python lit 7,9 s un élément écrit par Swift, sans dialogue)

- Python écrit puis Python relit (processus distincts) : **10 ms**. Swift écrit puis Swift relit : **11 ms**.
- Lecture par un autre binaire : 3 à 8 s, y compris l'outil `security` d'Apple (4,3 s). Ce n'est donc pas propre
  à Python ni à Swift, et pas une boîte de dialogue.
- ACL avec le vrai binaire Python (`/Library/Developer/CommandLineTools/usr/bin/python3`, et non le stub
  `/usr/bin/python3`) : Python reste lent (3,2 s). ACL « toute application » : Python reste lent (4,7 s).
- Hypothèse restante : la **liste de partitions** (partition ID) de l'élément, distincte de l'ACL classique.
  Elle ne se modifie qu'avec le mot de passe du trousseau (`security set-generic-password-partition-list`).

## Tour 4 : liste de partitions (testé en Terminal réel)

`security set-generic-password-partition-list -S "apple-tool:,apple:,unsigned:"` sur l'élément écrit par Swift :
Python relit toujours en **3,1 s**. L'hypothèse des partitions est **écartée**.

## Conclusion et décision pour la suite

La lenteur (3 à 8 s) frappe tout lecteur qui n'est pas le dernier écrivain ; elle n'est réglable ni par l'ACL,
ni par la liste de partitions. Retenu : l'app lit le coffre **une seule fois** (au lancement et après une
synchronisation) et le garde en mémoire ; seules les écritures retouchent le trousseau. Le stockage reste
derrière un protocole Swift (`VaultStore`) pour pouvoir basculer sur la CLI en repli. Effet attendu : une
attente de quelques secondes au premier affichage après qu'un autre processus a écrit.

Décisions §9 prises : moteur = cœur Swift natif ; code dans ce dépôt, dossier `macos/`.
