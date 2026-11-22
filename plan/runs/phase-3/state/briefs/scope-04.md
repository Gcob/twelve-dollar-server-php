# Brief: scope 4/7, pcntl, sockets, ext-event and Workerman in the images

**Worktree:** `phase-3-claude` (absolute path in your prompt) · **Run folder:** `plan/` of the main checkout
**Planned commit:** `feat(lab): pcntl, sockets, ext-event and Workerman in the images`

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scopes 1 to 3: `--ext`, `--env`, `--label`,
the shared server start logic in `lib.sh`, `conformance.sh`, `conns.sh`).

**Summary:** the source images get three shared extensions (`pcntl`, `sockets`, `event`) and two Workerman 5.2.4 trees
(stock, and with its 5 request caches patched out), proven by a caches script and a Workerman that boots.

**Today:** `lab/images/Dockerfile.src` builds PHP from the php.net tarball (version and sha256 from `lab_source_release`
in `lab/lib.sh`, through `lab/build.sh`) with `install-php-src.sh`, then Swoole when it builds, then copies `php-info`.
The images have `posix` but no `pcntl` and no `sockets`; no ext-event; no Workerman. `macro.sh`, `conformance.sh` and
`conns.sh` load extensions per server with `--ext` (default `swoole`). Workerman 5.2.4's source is cloned read-only in
`reference/workerman/` (tag v5.2.4) for reading; the image must fetch its own pinned tarball.

**Expected:**

- **A new last layer in `Dockerfile.src`** (after Swoole and before or after `php-info`, so the PHP and Swoole layers
  stay cached; check that a rebuild reuses them and say how long it took), with its own install script
  (`lab/images/install-extras.sh` or similar, reusable later as part of an `install.sh`):
  - **`pcntl` and `sockets`** built as shared extensions with `phpize` from the **same php.net tarball and sha256**
    the image was built from (`PHP_VERSION`, `PHP_SHA256` build args). Same `CFLAGS=-O2` as PHP.
  - **PECL `event` 3.2.0** (latest stable on 2026-11-21; re-check on pecl.php.net and say if newer), sha256 pinned in
    the repo, built against `libevent-dev` (pinned by the Ubuntu digest of the base image, like the rest). Configure it
    so it works with `sockets` loaded (event's sockets support needs `sockets` loaded **before** `event`: document the
    order). None of the three enabled globally: loaded with `-d extension=...`.
  - **8.6:** if `event` doesn't build on 8.6, save the error in `lab/results/event-on-php-8.6.md` (like
    `swoole-on-php-8.6.md`) and build that image without `event`, through a switch in `lab_source_release` or a build
    arg. `pcntl` and `sockets` come from 8.6's own tarball, so they should build.
  - **`8.3-apt`:** left as is (nothing in this phase runs Workerman or DIY on it). Say so in the README.
- **Workerman:** the v5.2.4 GitHub source tarball and `workerman/coroutine` v1.1.7 (what Workerman's `composer.json`
  accepts; re-check), both sha256 pinned, unpacked under `/opt/workerman/stock` and `/opt/workerman/nocache`. Each tree
  gets a small PSR-4 autoloader (`/opt/workerman/<tree>/autoload.php`, no Composer): the `Workerman\` prefix maps to
  **two roots** (Workerman's `src/` and the coroutine package's `src/`).
- **The patch:** `lab/images/workerman-nocache.patch`, applied to `nocache` at build time, removes the 5 request
  caches, which are **function-local `static` variables**, not properties:
  - `static $requests` in `TcpConnection::baseRead()` (`src/Connection/TcpConnection.php` around line 682);
  - `static $cache` in `Http::input()` (`src/Protocols/Http.php` around line 116);
  - the statics of `Request::parseHeaders()`, `parseGet()`, `parsePost()` (`src/Protocols/Http/Request.php` around
    lines 495, 540, 567).
  Behavior otherwise unchanged (the code computes what it would have cached, every time). **The build fails** if the
  patch doesn't apply cleanly, or if a grep still finds one of the 5 statics in the patched tree. Workerman is MIT:
  credit it in `lab/NOTICE.md` like mattsplat's code.
- **`php-info`:** adds `pcntl: present|missing`, `sockets: present|missing`, `event: <version>|not built`, and
  `workerman: 5.2.4 (stock, nocache)` (read from the trees, `Worker::VERSION`). It loads the shared extensions it
  reports on. The phase 2 lines stay byte-identical (`main`'s `check.sh` reads them on the same shared images).
- **`lab/servers/workerman-caches.php`:** runs one child process per tree (both trees declare the same classes). Each
  child feeds the same raw requests through Workerman's HTTP protocol twice: through a `TcpConnection` on a socket pair
  for `baseRead()` (an `EventInterface` instance is needed: Workerman's Select loop is enough for this), and calls
  `header()`, `get()` with a query string and `post()` with a form body (non-multipart) on the decoded `Request`; then
  reads the 5 statics with `ReflectionMethod::getStaticVariables()`. Output: one line per cache and tree, `filled` or
  `empty`, and exit 0 only if all 5 are filled on `stock` and all 5 empty on `nocache`.
- **A Workerman that boots:** a minimal check (in `check.sh`) that starts a Workerman HTTP `Worker` on each tree with
  `--ext pcntl --ext sockets --ext event`, `Worker::$eventLoopClass` set to the Event loop, `start` in argv, pid,
  status and log files in `/tmp` (not in `/lab`, mounted read-only), and gets one answer. A tiny throwaway server file
  for this check is fine (`lab/check/fixtures/workerman-hello.php`); scope 5 writes the real one.
- **`lab/check.sh`:** the 8.5 `php-info` lines for the new extensions and Workerman, the caches script, and the boot
  check. The source-image checks still pass on every image.
- **`lab/README.md`:** the extensions, how to load them (order), Workerman's two trees and the patch, the caches
  script; `lab/results/build-times.md` gets the rebuild times.
- **Rebuild:** `bash lab/build.sh 8.3`, `8.4`, `8.5`, `8.6` (one at a time). Other projects' containers on the VM
  don't matter for a build. Don't rebuild `8.3-apt`.

**Done when:** `bash lab/run.sh 8.5 php-info` prints `pcntl: present`, `sockets: present`, `event: <version>` and
`workerman: 5.2.4 (stock, nocache)`; `bash lab/run.sh 8.5 php /lab/servers/workerman-caches.php` prints the 5 caches
`filled` on `stock` and `empty` on `nocache` and exits 0; the boot check answers one request on each tree; `php-info`
on 8.6 shows `event` or `not built` with `lab/results/event-on-php-8.6.md`; `lab/check.sh` passes (report `N/N ok`).

**Seams and cases to test:**

- `php-info` on each source image: new lines present, old lines unchanged.
- The caches script: filled on stock, empty on nocache (red first: run it against two unpatched trees and see the
  `nocache` lines fail).
- The patch failing: show once, by hand, that a patch that doesn't apply (or a tree where one static remains) stops the
  build with a clear message; report the message (no check: `check.sh` doesn't rebuild).
- The boot check on both trees.

**Tests to imitate:** `lab/check.sh` → `check_source_image`, `check_image_8_5`.

**Decisions that touch you:**

- `pcntl`, `sockets`, `event` as shared extensions built with `phpize` from the same pinned tarballs, in a new last
  layer, loaded per server; the configure flags of PHP itself don't change.
- Workerman runs with its 5 caches patched out; one run with them on shows what they buy. The build fails loudly if
  the patch doesn't apply.
- Workerman and DIY run on ext-event (Workerman's Select loop is capped at 1,024 fds).
- Every download sha256 pinned, the build fails on a mismatch.

**Out of scope:** the Workerman bake-off server (scope 5), DIY (scope 6), any measurement.

**Where to look:** `lab/images/Dockerfile.src`, `lab/images/install-php-src.sh` (configure flags, cleanup: is `phpize`
and `autoconf` still there after the build?), `lab/build.sh`, `lab/lib.sh` → `lab_source_release`, `lab/images/php-info`
`@b14068f`; `reference/workerman/src/Worker.php` (lines 646-650 `pcntl` check, 771-779 pid/log files, 824-834 loop
choice, 1121-1132 argv, 2523-2533 `TCP_NODELAY` through `sockets`) `@4c817de`.

**Come back to me if:** `pcntl` or `sockets` won't load as shared extensions on 8.5 (then the fallback is configure
flags for every version, a decision for me), `event` doesn't build on 8.5, a decision is missing, or the "Done when"
doesn't pass after 3 tries.
