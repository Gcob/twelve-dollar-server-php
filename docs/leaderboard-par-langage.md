# $12 Server Challenge — Meilleur score par langage

> Source : `LEADERBOARD.md` du repo https://github.com/arjaythedev/twelve-dollar-server-challenge
> Classement au 2026-11-21. Score = nombre d'utilisateurs tenus 5 minutes avec p95 < 500 ms, p99 < 1 s et < 1 % d'erreurs.
> Machine : VPS 1 vCPU / 2 Go (Xeon Platinum 8260 @ 2.4 GHz), Ubuntu 24.04, sans swap ni tuning.

---

## 🐘 PHP — ce qu'il faut battre

| Soumission | PR | Stack | Utilisateurs | req/s | p95 ms | p99 ms | err % | CPU % | µs/req | RAM Mo |
|---|---|---|---|---|---|---|---|---|---|---|
| holyphp-io-uring-elifoxcoder | #490 | **HolyPHP** (compilé en C, io_uring, lecture des B-trees SQLite) | **270 000** | 25 816 | 234.0 | 584.6 | 0.00 | 84 | 29 | 1 325 |
| php-swoole-mattsplat | #24 | PHP + **Swoole** | **71 000** ᶠ | 6 552 | 45 | 103 | 0.93 | 66 | 94 | 1 025 |
| php-swoole-tzimpel | #28 | PHP + **Swoole** | **71 000** ᶠ | 6 552 | 17 | 175 | 0.93 | 71 | 101 | 325 |
| php-pype-dayne-valourite | #337 | PHP 8.3 (framework pype, OpenSwoole) | 37 000 | 3 626 | 250.9 | 573.1 | 0.00 | 90 | 231 | 329 |
| php-symfony-pklebba | #40 | PHP (Symfony, FrankenPHP) | 21 000 | 2 061 | 186 | 274 | 0.00 | 95 | 428 | 915 |
| php-symfony-gnugat | #338 | PHP (Symfony, FrankenPHP) | 19 000 | 1 863 | 253 | 608 | 0.00 | 92 | 459 | 1 090 |
| php-codeigniter-melroy89 | #50 | PHP (CodeIgniter, FrankenPHP) | 9 500 | 926 | 332 | 456 | 0.00 | 99 | 995 | 626 |

### À nuancer

**HolyPHP n'est pas vraiment du PHP.** C'est un langage à syntaxe PHP, compilé en C11 par un compilateur inclus dans la soumission (`toolchain/`). L'auteur a aussi réécrit le runtime : io_uring avec plusieurs rings, lecture directe des curseurs B-tree de SQLite, vérification JWT HS256 en C natif, group commit, checkpoints WAL en arrière-plan, mode direct sans Nginx. Dans les faits, c'est quasiment du C. Son README est un excellent journal d'optimisation, avec chaque expérience et ses mesures.

**Le vrai record en PHP « normal » est donc de 71 000, avec Swoole.**

**La note ᶠ (71 000)** marque un plafond commun à une vingtaine de soumissions de langages très différents. Elles sont toutes bloquées à exactement 71 000 avec 0,93 % d'erreurs. D'après les notes du leaderboard, ce plafond vient de la limite de descripteurs de fichiers / connexions en mode direct, pas du CPU. Le CPU des deux soumissions Swoole n'était qu'à 66–71 %, donc il reste de la marge si on contourne ce plafond.

**Les frameworks lourds** (Symfony, CodeIgniter) plafonnent à 9 500–21 000 et sont limités par le CPU (92–99 %, 430–1 000 µs/requête).

---

## 🏆 Meilleur score par langage

| Langage | Meilleure soumission | Utilisateurs |
|---|---|---|
| Rust | rust-iouring-kensac (#264) | 310 000 |
| F# | fsharp-uring-delneg (#437) | 310 000 |
| Mojo | mojo-iouring-oh-meh (#257) | 304 000 |
| C | c-iouring-jowinjestine (#486) | 300 000 |
| Swift | swift-iouring-akbashev (#376) | 300 000 |
| C++ | cpp-io_uring-0329-at (#522) | 290 000 |
| Objective-C | objc-uring-delneg (#326) | 290 000 |
| Go | go-iouring-DblD (#498) | 280 000 |
| C# | csharp-kestrel-btree-mbobka (#317) | 280 000 |
| Zig | zig-iouring-harshitkhandelwal208 (#460) | 280 000 |
| Assembleur x86-64 | asm-btree-ninhnv (#388) | 280 000 |
| Lean 4 | lean-derive-hargup (#153) | 280 000 |
| HolyPHP | holyphp-io-uring-elifoxcoder (#490) | 270 000 |
| Crystal | crystal-epoll-faustinoaq (#193) | 270 000 |
| Fortran | fortran-iouring-oh-meh (#332) | 270 000 |
| Goose | goose-iouring-ahmadsh2007 (#291) | 270 000 |
| V | v-epoll-i098 (#191) | 257 000 |
| Ada | ada-native-visseranalytics (#237) | 250 000 |
| LuaJIT | luajit-iouring-asxpi (#436) | 250 000 |
| Common Lisp | lisp-sbcl-heyitstony97-max (#283) | 247 000 |
| Java | java-iouring-davidhsv (#393) | 240 000 |
| Cider | cider-iouring-pomilon-v5 (#273) | 240 000 |
| Nelua | nelua-iouring-tbsvttr (#281) | 230 000 |
| Nexium | nexium-iouring-Londopy (#465) | 230 000 |
| DexLang | dexlang-iouring-tuned-ensamuel7 (#279) | 226 000 |
| WebAssembly (WAT) | wat-wasmedge-delneg (#288) | 220 000 |
| Julia | julia-iouring-amanica (#472) | 220 000 |
| Kotlin | kotlin-trikeshed-jnorthrup (#298) | 210 000 |
| SQL | sql-oneselect (#243) | 190 000 |
| Ruby | ruby-cring-cicloid (#309) | 160 000 |
| PyPy | python-pypy-iouring-kiwamizamurai (#284) | 155 000 |
| Brainfuck 😅 | brainfuck-iouring-harshitkhandelwal208 (#493) | 155 000 |
| Odin | odin-odinhttp-wanderingaura (#139) | 130 000 |
| COBOL | cobol-gnucobol-unorig-username (#185) | 126 000 |
| D | d-iouring-cyrusmsk (#163) | 114 000 |
| Lua (Neovim) | lua-neovim-unorig-username (#443) | 110 000 |
| Saad | saad-web-jakobsaadbye (#389) | 100 000 |
| Node | node-uwebsockets-zahidcakici (#102) | 97 000 |
| Bun | typescript-bun-xxmohamed012 (#3) | 90 000 |
| Scala | scala-netty-jacksonhoran (#107) | 90 000 |
| Lua (OpenResty) | lua-openresty-yar0slav (#94) | 88 000 |
| ArchBTW | archbtw-epoll-BlueFill (#200) | 85 000 |
| Python (CPython) | python-stdlib-shawal-mbalire (#118) | 75 000 |
| **PHP (Swoole)** | **php-swoole-mattsplat (#24) / php-swoole-tzimpel (#28)** | **71 000** ᶠ |
| Deno | typescript-deno-JakeAve (#119) | 71 000 ᶠ |
| Dart | dart-rawsocket-C-Hatton (#46) | 71 000 ᶠ |
| TypeScript (TinyJS sur Bun) | typescript-tinyjs-animuni-express (#410) | 71 000 ᶠ |
| TeX (LuaTeX) | tex-luatex-unorig-username (#468) | 71 000 ᶠ |
| Prolog | prolog-swipl-unorig-username (#471) | 71 000 ᶠ |
| Forth | forth-gforth-FantasticForth (#171) | 71 000 |
| Trux | trux-http-claudioscheer (#145) | 69 000 |
| Haskell | haskell-warp-staticfx (#104) | 55 000 |
| Ecko | ecko-stdhttp-sn (#334) | 55 000 |
| Koru | koru-orisha-denstad (#310) | 50 000 |
| Tcl | tcl-tclsh-unorig-username (#470) | 43 000 |
| Erlang | erlang-cowboy-tbsvttr (#11) | 28 000 |
| Emacs Lisp | elisp-emacs-unorig-username (#444) | 24 000 |
| Pascal | pascal-horse-viniabreu (#134) | 20 000 |
| GNU Octave | octave-sockets-unorig-username (#458) | 18 500 |
| Zsh | zsh-ztcp-unorig-username (#459) | 8 500 |
| Bash | bash-socat-framegrace (#89) | 3 500 |
| R | r-plumber2-josiahparry (#242) | 2 000 |
| SPICE (simulateur de circuits !) | spice-ngspice-public (#220) | 500 |

Soumissions en échec : nim-io_uring-NioHast (bloqué), v-fasthttp-ulises-jeremias (OOM à l'installation), v-epoll-quaesitor-scientiam (timeout à l'installation), d-arsd-threadedcgi-cyrusmsk (0 : timeouts dès 500 users).

---

## Tendances générales

- **Le haut du classement converge vers la même recette** : io_uring, lecture directe des B-trees de SQLite (plutôt que du SQL), mode direct sans Nginx, ~25–30 µs CPU/requête à 80–90 % de CPU.
- **Le plafond pratique** se situe autour de **280–310k utilisateurs (~27–29k req/s)**, limité par le CPU et la latence p99.
- **Plafond 71 000 (ᶠ)** : limite de connexions / descripteurs, ~0,93 % d'erreurs, quel que soit le langage.
- **Plafond 24 000** : plusieurs serveurs derrière Nginx s'y arrêtent.
- **RAM** : au-delà de ~1,5 Go on se rapproche de l'OOM sur 2 Go sans swap.

---

## 🎯 Plan d'attaque PHP

- **Objectif réaliste : dépasser 71 000 avec du vrai PHP.** Il faut passer en mode direct (sans Nginx) et tenir plus de connexions keep-alive que les soumissions Swoole.
- **Éviter les frameworks lourds** (Symfony, CodeIgniter) : ils sont limités par le CPU.
- **Les pistes qui marchent partout** :
  - prepared statements réutilisés ;
  - group commit des écritures (chaque réponse attend son commit) ;
  - checkpoints WAL bien gérés (éviter que le WAL grossisse puis bloque) ;
  - JSON construit à la main dans l'ordre exact des clés ;
  - vérification JWT la moins coûteuse possible (mais à chaque requête).
- **Lectures utiles** : le README de `submissions/holyphp-io-uring-elifoxcoder/` et ceux des deux soumissions Swoole (`php-swoole-mattsplat`, `php-swoole-tzimpel`).
