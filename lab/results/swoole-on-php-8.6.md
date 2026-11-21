# Swoole on PHP 8.6

Swoole 6.2.6 does not build on PHP 8.6.0, so the `8.6` image is built with `WITH_SWOOLE=0` (`php-info` prints
`swoole: not built`). The 8.3, 8.4 and 8.5 images have Swoole 6.2.6.

- **Date:** 2026-11-21 (PHP 8.6.0 was released on 2026-11-19).
- **Where:** `php-lab:8.6` (Ubuntu 24.04, arm64, GCC 13.2, PHP 8.6.0 built with the lab's flags), then the same steps as
  `lab/images/install-php-src.sh`: `phpize`, `./configure --disable-brotli --disable-zstd`, `make -j8`.
- **Result:** `configure` passes, `make` exits 2.

## Swoole 6.2.6 (tarball sha256 `b0a97398d50dc9442d48a71238cafa5f75d2c53d2e35d12a59235f9d52dab718`)

224 error lines. The first thing in the way is an explicit guard, then PHP APIs that 8.6 no longer has:

```text
ext-src/php_swoole_private.h:121:2: error: #error "require PHP version 8.5 or earlier"
ext-src/php_swoole_private.h:550:104: error: 'ZVAL_IS_NULL' was not declared in this scope; did you mean 'ZVAL_IS_BOOL'?
ext-src/php_swoole_cxx.h:695:44: error: 'XtOffsetOf' was not declared in this scope; did you mean 'offsetof'?
ext-src/swoole_socket_coro.cc:877:13: error: 'zval_is_true' was not declared in this scope; did you mean 'zend_is_true'?
ext-src/swoole_socket_coro.cc:1233:36: error: 'ZEND_PARSE_PARAMS_THROW' was not declared in this scope; did you mean 'ZEND_PARSE_PARAMS_QUIET'?
ext-src/swoole_socket_coro.cc:1755:9: error: 'zval_dtor' was not declared in this scope; did you mean 'zval_ptr_dtor'?
```

Most of the errors repeat one cause: `ZVAL_IS_NULL` (a macro in `php_swoole_private.h`, expanded 111 times in the
error log), then `XtOffsetOf`, `zval_is_true`, `zval_dtor` and `ZEND_PARSE_PARAMS_THROW`. The `#error` shows up once per
source file that includes the header (8 times).

## Swoole 6.3.0-rc2, for information only (tarball sha256 `3065da13374105ee1fef8ecb0f8e9f7b67b0f639cc2f2676ea284c144b210e63`)

Same result: `configure` passes, `make` exits 2, 229 error lines, the same `#error "require PHP version 8.5 or
earlier"` (now at `php_swoole_private.h:151`) and the same removed names (`ZVAL_IS_NULL`, `zval_is_true`, `XtOffsetOf`,
`zval_dtor`, `ZEND_PARSE_PARAMS_THROW`). Not adopted: the images keep Swoole 6.2.6 everywhere.

## Is there a trivial fix?

No. The version guard is deliberate, and about five removed names (`ZVAL_IS_NULL`, `zval_is_true`, `XtOffsetOf`,
`zval_dtor`, `ZEND_PARSE_PARAMS_THROW`) would need porting to their 8.6 replacements, and further errors may sit
behind these once the compiler gets past them. Nothing was patched. A Swoole release that supports 8.6 is needed.
