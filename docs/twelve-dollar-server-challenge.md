# The $12 Server Challenge — Documentation complète

> Source : https://github.com/arjaythedev/twelve-dollar-server-challenge (licence MIT)
> Leaderboard : https://benchmarks.arjaythedev.com/12-dollar-server · `LEADERBOARD.md` dans le repo
> Vidéo d'origine (8 langages, code non optimisé) : https://www.youtube.com/watch?v=sQXFhh_PiG4
> Extrait le 2026-11-21 (commit `162699a`)

---

## 1. Le principe

**Combien d'utilisateurs un serveur à 12 $/mois (1 vCPU, 2 Go de RAM) peut-il encaisser ?**

Tu implémentes une petite API (un mini-Twitter : 5 endpoints) **sur SQLite**, dans le langage/framework de ton choix, aussi rapide que possible. L'auteur la benchmarke ensuite sur la même VM que tout le monde avec k6.

**Score** = le plus grand nombre d'utilisateurs simultanés qui tiennent **5 minutes** avec :
- p95 < 500 ms
- p99 < 1 s
- erreurs < 1 %

---

## 2. Contenu du repo

| Fichier | Rôle |
|---|---|
| `SPEC.md` | L'API à implémenter : 5 endpoints, JSON et erreurs exacts |
| `schema.sql` | Le schéma SQLite (figé) |
| `seed/make-seed.sh` | Construit `seed/feed.db` (50k users, 500k posts, 2M likes) et `seed/tokens.json` |
| `test/test.sh` | La suite de tests (42 checks) — il faut **tout** passer |
| `test/golden/*.json` | Réponses attendues octet par octet (feed + quelques posts) |
| `test/run.sh` | Build ta soumission, la lance sur une copie fraîche de la DB et lance les tests (= ce que fait la CI) |
| `bench/load.js` | Le test de charge k6 utilisé pour le score |
| `bench/nginx.conf` | La config Nginx devant ton serveur (si tu choisis Nginx) |
| `submissions/` | Un dossier par participant |

---

## 3. Démarrage rapide

```bash
git clone https://github.com/arjaythedev/twelve-dollar-server-challenge
cd twelve-dollar-server-challenge

bash seed/make-seed.sh                          # node >= 18 + sqlite3 ; ~1 minute
mkdir submissions/<langage>-<framework>-<ton-user-github>
# → ton code + install.sh, build.sh, start.sh, README.md, .gitignore
bash test/run.sh submissions/<ton-dossier>      # nécessite curl, jq, openssl
k6 run -e VUS=1000 bench/load.js                # optionnel : test de charge local
```

Exemple de nom de dossier : `rust-axum-yourname`.

---

## 4. Règles

### La stack
1. **N'importe quel** langage, framework, runtime, driver/binding SQLite. Autant de processus/threads que tu veux.
2. La base est **SQLite** : le fichier à `$SQLITE_PATH`, utilisé **in-process**. Aucune autre base, aucun serveur de cache ni service externe (pas de Postgres, Redis, Memcached).
3. Schéma et données **figés** : ne pas ajouter/modifier tables, colonnes, index ou triggers. N'importe quel SQL contre le schéma tel quel.

### Correction
4. Passer `test/test.sh` à **100 %**, avec exactement les octets attendus.
5. **Aucun cache entre requêtes.** Chaque requête lit ses données dans SQLite pendant qu'elle est servie :
   - interdit : caches de réponses, caches de résultats de requêtes, copies en mémoire des tables, vérifications JWT mémorisées (vérifier la signature de **chaque** token) ;
   - autorisé : le page cache et le mmap de SQLite, et la réutilisation des prepared statements (ils cachent le plan, pas les données).
6. **Écritures durables avant de répondre.** Un 201 = la ligne est commitée.
   - WAL avec `synchronous=NORMAL` ou plus strict.
   - Interdit : `synchronous=OFF`, `journal_mode=OFF/MEMORY`, base en mémoire.
   - Le **group commit** (plusieurs requêtes dans une transaction) est autorisé si chaque réponse attend son commit.
7. Pas de réponses codées en dur, pas de détection du test de charge, rien qui ne marche que parce que c'est un benchmark.

### La VM
8. Ubuntu 24.04 x86_64, 1 vCPU, 2 Go RAM, **pas de swap**. CPU et RAM partagés avec l'OS (et Nginx). **Si tu manques de mémoire, tu perds.**
   - À noter : le leaderboard actuel tourne sur un VPS Synteq (KVM, Xeon Platinum 8260 @ 2.4 GHz avec AVX-512, 1 967 Mo de RAM, kernel 6.8, sans UFW ni tuning). Les tout premiers runs sur DigitalOcean étaient ~2× plus lents en CPU et ont tous été relancés.
9. **Nginx optionnel** — à préciser dans ton README :
   - **Derrière Nginx** (`bench/nginx.conf`) : écoute sur `127.0.0.1:3000`.
   - **Direct** : écoute sur `0.0.0.0:80`. Économise le CPU de Nginx (14–20 % dans la vidéo), mais ton serveur doit gérer jusqu'à **~15 000 connexions keep-alive** ouvertes.
10. Build **depuis les sources sur la machine** via `install.sh` et `build.sh`. Versions de dépendances **épinglées**, pas de binaires précompilés. Le serveur doit être healthy **dans les 60 s** après `start.sh`.
11. Rien n'est tuné pour toi : pas de paramètres kernel, pas d'épinglage CPU. Les réglages internes à ton process (GC, threads, allocateur, pragmas autorisés par la règle 6) sont permis.

---

## 5. Spécification de l'API

> En cas de désaccord entre la spec et `test/test.sh`, **le test gagne**.

### Variables d'environnement

| Variable | Valeur sur la machine de bench |
|---|---|
| `SQLITE_PATH` | chemin d'une copie fraîche de `seed/feed.db` (mode WAL) |
| `JWT_SECRET` | `twelve-dollar-challenge` |
| `HOST`, `PORT` | `127.0.0.1`, `3000` derrière Nginx ; `0.0.0.0`, `80` en direct |

- HTTP/1.1 avec **keep-alive**. Compression optionnelle.
- **Derrière Nginx** : Nginx garde jusqu'à 64 connexions idle vers toi. Garde les connexions idle ouvertes **au moins 65 s** (sinon Nginx peut réutiliser un socket que tu viens de fermer).
- **Direct** : chaque utilisateur k6 tient sa propre connexion → jusqu'à ~15 000 connexions. Le service reçoit `LimitNOFILE=65535` et `CAP_NET_BIND_SERVICE` (il ne tourne pas en root).

### Format des réponses
- JSON **compact**, `Content-Type: application/json` (`; charset=utf-8` OK). Newline final OK.
- **L'ordre des clés est exactement celui indiqué.**
- **Objet post** :
  ```json
  {"id":<int>,"body":<string>,"created_at":<string>,"author":<string>,"like_count":<int>}
  ```
  - `author` = `users.username` de l'auteur.
  - `like_count` = nombre de lignes dans `likes` pour ce post, **au moment de la requête**.
  - `created_at` = UTC, précision milliseconde, suffixe `Z` (ex. `2025-12-31T23:59:19.409Z`). Stocké exactement dans ce format → renvoyer tel quel. Les nouvelles lignes utilisent le défaut `strftime('%Y-%m-%dT%H:%M:%fZ','now')`.
- Échapper `<>&/` ou le non-ASCII est optionnel. Les payloads de charge sont en ASCII.

### Endpoints

| Requête | Succès | Corps |
|---|---|---|
| `GET /health` | 200 | `{"status":"ok","db":"ok","uptime_s":<int>}` après un `SELECT 1` réussi. En cas d'échec : **503** `{"status":"degraded","db":"unreachable","error":<string>}` |
| `GET /feed` | 200 | `{"posts":[<post> × 20]}` — les 20 plus récents, `ORDER BY created_at DESC, id DESC` |
| `GET /posts/:id` | 200 | `{"post":<post>}` |
| `POST /posts` (auth) | 201 | `{"post":{"id":…,"body":<body trimé>,"created_at":…,"author":<username du token>,"like_count":0}}` — requête : `{"body":"..."}` |
| `POST /posts/:id/like` (auth) | **201** la 1re fois, **200** ensuite | `{"liked":true,"already_liked":<bool>,"post_id":<int>}` — un like par (user, post) |

### Requêtes de référence (celles de la vidéo, une par requête)

```sql
-- objet post (+ "ORDER BY p.created_at DESC, p.id DESC LIMIT 20" pour le feed, ou "WHERE p.id = ?")
SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
FROM posts p JOIN users u ON u.id = p.user_id;

INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at;

INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING;
```

### Erreurs

Tout corps d'erreur : `{"error":"<message>"}`

| Condition | Status | Message |
|---|---|---|
| chemin inconnu | 404 | `not found` |
| `:id` n'est pas un entier positif (`0`, `-1`, `abc`, `1.5`) | 400 | `invalid post id` |
| le post n'existe pas (GET ou like) | 404 | `post not found` |
| pas de header `Authorization`, ou ne commence pas par `Bearer` | 401 | `missing bearer token` |
| mauvaise signature, expiré, pas HS256, ou JWT malformé | 401 | `invalid or expired token` |
| JWT valide mais `sub` n'est pas une chaîne d'entier positif, ou `username` n'est pas une chaîne | 401 | `invalid token payload` |
| le corps de requête n'est pas du JSON valide | 400 | `malformed JSON body` |
| `body` absent, pas une chaîne, ou vide après trim | 400 | `body is required` |
| `body` > 500 caractères après trim | 400 | `body must be at most 500 characters` |
| tout le reste | 500 | `internal server error` |

**Ordre des vérifications sur les routes authentifiées : auth d'abord, puis l'id.**
`POST /posts/abc/like` sans token → 401 ; avec un token valide → 400.

### Authentification
- `Authorization: Bearer <jwt>`, signé **HS256** avec `JWT_SECRET`.
- Payload : `{"sub":"<user id>","username":"<name>","iat":…,"exp":…}`
- Vérifier la signature **et** `exp`, n'accepter **que** HS256 (rejeter `alg: none`).
- L'id utilisateur = l'entier dans `sub` ; `username` est utilisé tel quel (pas de lookup en base).
- Pas d'endpoint de login. `seed/make-seed.sh` écrit des tokens pré-signés pour les users 1–20 000 dans `seed/tokens.json`.

### Hors périmètre (non testé — fais ce que fait ton framework)
Corps > 16 Ko, ids > 2^53, ids en hex ou en notation exponentielle, mauvaises méthodes HTTP sur des chemins connus.

---

## 6. Schéma SQLite (`schema.sql`, figé)

```sql
-- Timestamps en TEXT au format exact du fil (YYYY-MM-DDTHH:MM:SS.mmmZ, UTC), qui trie aussi correctement.
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE posts (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE likes (
  user_id INTEGER NOT NULL REFERENCES users(id),
  post_id INTEGER NOT NULL REFERENCES posts(id),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
CREATE INDEX posts_user_id_idx ON posts (user_id);
CREATE INDEX likes_post_id_idx ON likes (post_id);
```

Volume du seed : 50 000 users, 500 000 posts, 2 000 000 likes. Le user 1 s'appelle `golden_ember_1`.

---

## 7. La suite de tests (`test/test.sh`, 42 checks)

⚠️ À lancer contre un serveur démarré sur une **copie fraîche** de `seed/feed.db` : le test compare les octets exacts avec `test/golden/*.json` puis écrit un post et des likes, donc un 2e run sur la même base échoue. (`test/run.sh` s'en charge.)

Ce qui est vérifié :

**Lectures golden (base fraîche)**
- `GET /feed` == `golden/feed.json` octet par octet + Content-Type JSON
- `GET /posts/<id>` == chaque `golden/post-<id>.json` + Content-Type JSON

**Health, 404, validation d'id**
- `GET /health` → 200, corps matchant `^{"status":"ok","db":"ok","uptime_s":[0-9]+}$`
- `GET /nope` → 404 `not found`
- `GET /posts/0`, `/-1`, `/abc`, `/1.5` → 400 `invalid post id`
- `GET /posts/999999999` → 404 `post not found`

**Auth** (sur `POST /posts`)
- pas de token → 401 `missing bearer token`
- `Basic abc` → 401 `missing bearer token`
- `Bearer abc` → 401 `invalid or expired token`
- mauvaise signature → 401 `invalid or expired token`
- `alg=none` → 401 `invalid or expired token`
- token expiré → 401 `invalid or expired token`
- `sub` = `"abc"` → 401 `invalid token payload`
- pas de `username` → 401 `invalid token payload`
- `POST /posts/abc/like` sans token → 401 (auth avant id)

**Validation de création**
- `{"body":""}`, `{"body":" "}`, `{"body":123}`, `{}` → 400 `body is required`
- `{bad json` → 400 `malformed JSON body`
- 501 caractères → 400 `body must be at most 500 characters`

**Création, like, relecture**
- Body avec caractères spéciaux (`<b>&amp;</b> "quoted" / café ✓`, entouré d'espaces) → 201, body trimé qui fait l'aller-retour
- Post de 500 caractères (entouré d'espaces) → 201 avec la réponse exacte, `created_at` au bon format et à ±60 s de l'heure UTC actuelle
- 1er like → 201 `already_liked:false` ; 2e like → 200 `already_liked:true`
- Like sur post inexistant → 404 ; like sur `abc` avec token → 400
- Relecture du post → `like_count: 1`
- Like sur le post seedé 1 → compté immédiatement (golden + 1)
- `GET /feed` : 20 posts, le nouveau post en tête, entrée identique au post

Dépendances : `curl`, `jq`, `openssl`.

### Ce que fait `test/run.sh` (= la CI)
1. Vérifie que `seed/feed.db`, `build.sh` et `start.sh` existent.
2. Exporte `JWT_SECRET=twelve-dollar-challenge`, `HOST=127.0.0.1`, `PORT=3000` (surchargeable), copie la DB dans un dossier temporaire → `SQLITE_PATH`.
3. Lance `build.sh`, puis `start.sh` en arrière-plan (logs dans `server.log`).
4. Attend jusqu'à 60 s que `/health` réponde.
5. Lance `test/test.sh` ; en cas d'échec, affiche les 30 dernières lignes du log.

> `install.sh` doit être lancé toi-même au préalable (une fois, en root).

---

## 8. Le test de charge (`bench/load.js`, k6)

```bash
k6 run -e VUS=2000 bench/load.js
k6 run -e BASE_URL=http://10.0.0.5 -e VUS=8000 bench/load.js
```

Variables : `BASE_URL` (défaut `http://127.0.0.1:3000`), `VUS` (défaut 100), `DURATION` (défaut `5m`), `RAMP_UP` (défaut `60s`), `TOKENS` (défaut `seed/tokens.json`).

**Modèle d'un utilisateur virtuel** (1 VU = 1 personne qui navigue, avec temps de réflexion) :
1. `GET /feed`
2. pause 3–7 s
3. `GET /posts/:id` (un post pris au hasard dans le feed)
4. pause 3–8 s
5. like ce post (**15 %** de chance)
6. écrit un post (**2 %** de chance)
7. pause 5–15 s → recommence

Au 1er tour, chaque VU attend 0–5 s pour étaler les démarrages. Chaque VU utilise le token `tokens[(VU-1) % n]`.

Scénario : `ramping-vus` — montée sur `RAMP_UP`, palier `DURATION` à `VUS`, descente 30 s.
Seuils : `http_req_duration` p95 < 500 ms et p99 < 1000 ms ; `http_req_failed` < 1 %. k6 sort en non-zéro si échec.

> Concrètement, le trafic est **très majoritairement en lecture** (feed + post), avec peu d'écritures. Un user fait ~1 requête toutes les ~10 s → 300 000 users ≈ 28–29k req/s.

---

## 9. Config Nginx (`bench/nginx.conf`, non modifiable)

```nginx
# /etc/nginx/nginx.conf fixe aussi worker_rlimit_nofile 65535 et worker_connections 16384.
upstream app {
    server 127.0.0.1:3000;
    keepalive 64;
}

log_format bench '$remote_addr [$time_local] "$request" $status $body_bytes_sent '
                 'rt=$request_time urt=$upstream_response_time';

server {
    listen 80 default_server;
    server_name _;

    access_log /var/log/nginx/bench.access.log bench buffer=64k flush=5s;
    error_log  /var/log/nginx/bench.error.log warn;

    gzip on;
    gzip_types application/json;
    gzip_min_length 1024;

    location / {
        proxy_pass http://app;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
    }
}
```

---

## 10. Soumettre

Ouvrir une **pull request** qui ajoute **un seul dossier** : `submissions/<langage>-<framework>-<github-username>/`

| Fichier | Rôle |
|---|---|
| `install.sh` | Lancé une fois **en root** sur un Ubuntu 24.04 vierge : installe toolchain/runtime (apt, tarballs officiels) |
| `build.sh` | Build l'app en **utilisateur normal** (peut télécharger des dépendances épinglées) |
| `start.sh` | Lance le serveur **au premier plan**, configuré uniquement par les variables d'env de la spec |
| `README.md` | Langage, framework, driver et versions ; Nginx ou direct ; les optimisations faites et pourquoi |
| ton code | Sources uniquement — pas de `bin/`, `target/`, `node_modules/`… Ajouter un `.gitignore` |

Exemple (Go) :

```bash
# install.sh : une fois en root sur Ubuntu 24.04 vierge
set -euo pipefail
apt-get update && apt-get install -y build-essential curl
curl -fsSL https://go.dev/dl/go1.27.1.linux-amd64.tar.gz | tar -C /usr/local -xz
```
```bash
# build.sh : en utilisateur normal
set -euo pipefail
cd "$(dirname "$0")" && /usr/local/go/bin/go build -o bin/server .
```
```bash
# start.sh : serveur au premier plan
exec "$(dirname "$0")/bin/server"
```

- La CI lance `install.sh` puis `test/run.sh` sur chaque PR : elle doit être **verte**.
- Ne touche **aucun fichier hors de ton dossier**.
- En soumettant, ton code passe sous licence **MIT**.
- Après merge, la soumission attend le prochain **batch** de benchmarks (pas de calendrier fixe).

---

## 11. Scoring en détail

Chaque soumission valide est benchmarkée sur la même machine, avec k6 sur des machines séparées.

1. **Échauffement** : 1 000 users pendant 2 min (non compté).
2. **Trouver la limite** : `bench/load.js` à partir de 2 500 users, en **doublant** jusqu'à un échec, puis bisection jusqu'à ±250 users (le leaderboard précise : sondes de 2 min, bisection à ~5 %).
3. **Confirmer** : un palier de **5 min** à ce nombre. En cas d'échec, on descend (de 250 users / ~5 %) et on recommence.

Détails tirés de `LEADERBOARD.md` :
- Lancé par systemd en utilisateur `deploy`, `LimitNOFILE=65535`, `CAP_NET_BIND_SERVICE`, sur une copie fraîche du seed ; les 42 tests sont vérifiés avant toute charge.
- Générateurs de charge : machines 16 cœurs dans le même datacenter (RTT 0,25 ms).
- **Chaque sonde redémarre l'app sur une base fraîche.**
- Le leaderboard publie aussi : req/s, p95, p99, % d'erreurs, % CPU, µs CPU/requête et pic RAM (cgroup de l'app).

---

## 12. État du leaderboard (au 2026-11-21, extrait)

| # | Soumission | Langage / approche | Users tenus 5 min | req/s | RAM Mo |
|---|---|---|---|---|---|
| 1 | rust-iouring-kensac | Rust (io_uring, lectures B-tree SQLite) | 310 000 | 29 284 | 1 114 |
| 1 | fsharp-uring-delneg | F# (.NET 11, io_uring, B-tree) | 310 000 | 29 243 | 823 |
| 3 | mojo-iouring-oh-meh | Mojo (io_uring, B-tree) | 304 000 | 28 705 | 726 |
| 4 | rust-iouring-rkkautsar | Rust (io_uring, B-tree) | 300 000 | 28 417 | 1 159 |
| 4 | swift-iouring-akbashev | Swift (io_uring, B-tree) | 300 000 | 28 183 | 1 240 |
| 4 | c-iouring-jowinjestine | C (io_uring, B-tree) | 300 000 | 28 394 | 1 503 |

Quelques repères plus « classiques » :

| Soumission | Users tenus |
|---|---|
| csharp-kestrel-mbobka (Kestrel, io_uring) | 260 000 |
| go-epoll-MegaPanchamZ (Go, epoll brut) | 185 000 |
| node-uwebsockets (Node, uWebSockets) | 97 000 |
| typescript-bun | 90 000 |
| rust-axum-tbsvttr (Axum) | 76 000 |
| python-fastapi-granian | 70 000 |
| go-nethttp-tbsvttr (net/http) | 53 000 |
| ruby-rails | 9 000 |

**Enseignements visibles :**
- Le haut du classement converge vers **io_uring + lecture directe des B-trees SQLite** (curseurs bas niveau plutôt que du SQL), ~25–30 µs CPU/requête, ~80–90 % CPU.
- Le plafond pratique se situe autour de **280–310k users (~27–29k req/s)**, limité par le CPU et la latence p99.
- Beaucoup de soumissions plafonnent à exactement **71 000** (note ᶠ) : plafond de descripteurs de fichiers / connexions en mode direct, avec ~0,93 % d'erreurs.
- Derrière Nginx, plusieurs serveurs plafonnent à **24 000** users.
- Surveiller la **RAM** : au-delà de ~1,5 Go on se rapproche de l'OOM sur une machine de 2 Go sans swap.
- Les WAL checkpoints et le group commit sont des leviers fréquemment cités dans les notes.

---

## 13. Checklist pour démarrer le projet

- [ ] Cloner le repo, installer `node >= 18`, `sqlite3`, `curl`, `jq`, `openssl`, `k6`
- [ ] `bash seed/make-seed.sh`
- [ ] Choisir langage + framework + driver SQLite ; choisir **Nginx ou direct**
- [ ] Créer `submissions/<langage>-<framework>-<user>/` avec `install.sh`, `build.sh`, `start.sh`, `README.md`, `.gitignore`
- [ ] Lire config uniquement via `SQLITE_PATH`, `JWT_SECRET`, `HOST`, `PORT`
- [ ] Pragmas : `journal_mode=WAL`, `synchronous=NORMAL` (minimum), prepared statements réutilisés
- [ ] Implémenter les 5 endpoints avec ordre des clés exact et JSON compact
- [ ] JWT HS256 vérifié à **chaque** requête (signature + `exp`, rejet de `alg:none`)
- [ ] Toutes les erreurs aux messages exacts ; auth avant validation d'id
- [ ] Keep-alive ≥ 65 s (derrière Nginx) ou ~15k connexions (direct)
- [ ] Healthy en < 60 s
- [ ] `bash test/run.sh submissions/<dossier>` → 42/42
- [ ] `k6 run -e VUS=… bench/load.js` en local, surveiller p95/p99/RAM
- [ ] Pas de cache de données, pas de détection du bench
- [ ] Dépendances épinglées, pas de binaires commités
- [ ] README : versions, Nginx/direct, optimisations et pourquoi
- [ ] PR qui ne touche que ton dossier, CI verte
