# Excimer on PHP 8.6

Excimer 1.2.6 (the latest stable PECL release, 2026-04-16) does not build on PHP 8.6.0, so the `8.6` image is built with
`WITH_EXCIMER=0` (`php-info` prints `excimer: not built`). The 8.3, 8.4 and 8.5 images have Excimer 1.2.6.

- **Date:** 2026-11-22.
- **Where:** `php-lab:8.6` (Ubuntu 24.04, arm64, GCC 13.3, PHP 8.6.0 built with the lab's flags), through
  `lab/images/install-excimer.sh`: `phpize`, `./configure CFLAGS=-O2`, `make -j8`.
- **Result:** `configure` passes, `make` exits 2 on `excimer.c`, 58 error lines.

## Excimer 1.2.6 (tarball sha256 `7b5fe1f68f2b1a62bd0394d4bf165eafe6b7ceb3fc20ab885e733d356db0d034`)

Two names that PHP 8.6 no longer has, each used by a macro that repeats the error where it expands:

```text
excimer.c:514:42: warning: implicit declaration of function 'XtOffsetOf'; did you mean 'offsetof'? [-Wimplicit-function-declaration]
excimer.c:517:32: error: expected expression before 'ExcimerProfiler_obj'
excimer.c:520:32: error: expected expression before 'ExcimerLog_obj'
excimer.c:1540:21: note: in expansion of macro 'EXCIMER_OBJ_ZP'
warning: implicit declaration of function 'INI_INT' [-Wimplicit-function-declaration]
```

`XtOffsetOf` (used by `REGISTER_EXCIMER_CLASS` and `EXCIMER_OBJ`, so every class registration and every object access)
is what the 58 `expected expression` errors come from, and `INI_INT` is the second removed name. `offsetof` and
`zend_ini_long` look like the replacements, but nothing was patched: the extension's ZTS and signal code was not read for
other 8.6 changes behind these two. An Excimer release that supports 8.6 is needed. The profile of the next phase runs on
8.5.
