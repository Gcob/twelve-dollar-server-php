# pr-reviewer : phase 4, realistic baseline

**État :** passe 1 faite le 2026-11-22 à 17:55 sur `0eba220..phase-4-claude` (HEAD `1acc81a`). Verdict OK, aucun 🔴 ni 🟠,
9 🟡, 1 ⚠️. Rapport : `plan/reviews/PR-2026-11-22-1755.md`.

## Vérifié

- Les 6 scopes sont livrés, avec les écarts réglés par D45 à D47 ou dits dans le README du baseline. **Preuve :** lecture de
  `details/phase-4.md`, de `decisions.md`, du diff de `lab/`, du README du baseline et de `summarize.sh`.
- Le code mesuré est celui de HEAD : les corrections du harnais (`38fc153` 15:03, `fcf104f` 15:25 locales) précèdent les
  premières courses comptées (20:48 UTC = 15:48). **Preuve :** `git log --format='%h %ad'` et `run-times.txt`.
- Aucun chemin `/Users/`, courriel ou identifiant de compte ajouté. **Preuve :** `git grep` sur `lab` et le diff.
- Les renvois `D5`, `D31`, `D35`, `D40`, `Q10` du README du baseline sont dans le bloc des prédictions recopié tel quel, et
  `plan/` est versionné dans ce dépôt : pas relevés.
- Les chiffres recoupés du README : 53 stalls = 21 + 16 + 16, 44 outside + 9 mixed, k6 à 38 % des 8 CPU, 6 prédictions sur 12.
  **Preuve :** `jq` sur `hold-*.json`.
- `longest_callback_ms` médian de 11,2 ms et 99 % des secondes au-dessus de 5 ms à 24 000 req/s (hold-1, hold-2), contre 0,5
  ms à 7 000 req/s (`q10-cold-1`, `q10-warm-2`). **Preuve :** `jq` sur `.results.series` et `.results.per_second.rows`.

## Supposé

- Que `Pss_Anon` monte à cause des index de `likes` (autre explication que celle du README) : je ne l'ai pas vérifié.
- Que le ~11 ms par seconde vient de l'échantillonneur (`smaps_rollup`, `/proc/<pid>/fd`), de la télémétrie ou du vCPU :
  aucune donnée ne les sépare. Une course sans échantillonneur le dirait. Pas de nouvelle mesure possible (VM occupée).
- Je n'ai pas lancé `check.sh` ni de course (VM occupée, pas de mesure) : je m'appuie sur les 59 sur 59 du chargé de projet.

## Impasses

- Je n'ai pas relu les 440 000 lignes de JSON ni tout `check.sh` (701 lignes ajoutées) : sondage des vérifications du
  plan, de `check_results_regenerate` et de sa fixture seulement.

## Décisions en route

- Les écarts du scope 5 (escalier à 18 000, trois courses de 60 s comptées malgré 96,7 à 97,0 %) sont des décisions actives de
  `decisions.md` (D46, D47) : conformes. Seule la question de fond (second générateur, mesure du labo d'étapes) va en ⚠️.

## Remarques et suites

| #  | Où | Statut |
|----|----|--------|
| ⚠️ 1 | `details/phase-4.md` Done-when, D46, D47 : débit tenu = plancher du harnais | ouverte, question pour Jacob |
| 1  | `README.md:408-411` (baseline) : explication de `Pss_Anon` | ouverte |
| 2  | `README.md:440` : « 7 fois » compare les routes sans le travail partagé | ouverte |
| 3  | `README.md:259`, `:416` : S1 et S2 contiennent l'ouverture des 60 000 inactives | ouverte |
| 4  | `README.md:399`, `:441` : « at least » de D47 absent | ouverte |
| 5  | `lab/realistic.sh:94`, `lab/macro/aggregate.php:128,144,164` : garde de lag par défaut, maximum en course | ouverte |
| 6  | `README.md:404-407`, `:425-426` : callback de 11 ms par seconde non expliqué | ouverte |
| 7  | `lab/README.md` (tableau de calibration) : chiffres tapés à la main, dossier non couvert | ouverte |
| 8  | `lab/realistic.sh:293` et `lab/macro.sh:229` : bloc `cold_json` dupliqué | ouverte |
| 9  | `lab/check.sh:491` : tolérance de 3 % contre 1 % au plan | ouverte |

## Prochaines étapes

1. Relance du chargé de projet : relire seulement les nouveaux commits et ce qu'ils touchent.

## Questions pour le chargé de projet

- ⚠️ 1 pour Jacob : le CPU par requête suffit-il pour le labo d'étapes, ou faut-il ouvrir la question d'un second générateur
  avant la phase 5 ?

## Rétro

1. **Ce qui m'a manqué :** rien de bloquant. Le plan, les décisions et le README du baseline tiennent seuls.
2. **Ce que j'ai deviné :** l'origine du callback de 11 ms par seconde (échantillonneur, télémétrie ou vCPU), non tranché
   par les données du run : dit comme hypothèse dans le rapport.
3. **Où j'ai perdu du temps :** `realistic.sh` (718 lignes) et `check.sh` (701) en lecture complète seraient trop longs :
   j'ai lu les chemins qui portent un contrat du plan. Rien d'autre.
4. **Consigne inutile ou contradictoire :** le gabarit demande « Description de la PR » et « Rien qui pointe vers le plan », alors
   que `plan/` est versionné dans ce dépôt : les `D5`, `Q10` du README ne sont pas des renvois perdus ici. J'ai appliqué la
   règle aux commentaires et à la description, pas au bloc de prédictions recopié.
5. **Ce qui aurait pu être déterministe :** une vérification dans `check.sh` qui compare le bloc des prédictions du README du
   baseline à `details/phase-4.md` (le chargé de projet l'a fait à la main au scope 5). Brancher dans `check_results_regenerate`
   ou dans une vérification à part.
6. **Ce que le plan aurait dû trancher :** ce que « the highest load it holds » veut dire quand le générateur est le facteur
   limitant (D47 le tranche après coup) ; et que l'échantillonneur de `/proc` est un instrument qui peut perturber le serveur.
7. **Un angle mort :** personne ne mesure le coût de l'échantillonneur lui-même (la télémétrie a sa paire, pas lui).
