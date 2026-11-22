# Third-party notice

## Workerman

`lab/images/workerman-nocache.patch` is a modification of Workerman 5.2.4, <https://github.com/walkor/workerman>
(Copyright (c) walkor and contributors), which the images download (`lab/images/install-extras.sh`) and run. Workerman is
under the MIT License, with the notice below; `workerman/coroutine` (Copyright (c) 2025 workerman), which it requires, is
under the MIT License too.

```text
MIT License

Copyright (c) 2009-2025 walkor and contributors (see https://github.com/walkor/workerman/contributors)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## The challenge repository

`lab/images/install-php83-apt.sh`, `lab/servers/noop-swoole.php`, `lab/servers/bake-swoole.php` and `lab/servers/handler.php`
are adapted from the `php-swoole-mattsplat` entry (`install.sh`, the Swoole settings and the SQLite pragmas of `server.php`) of
the challenge repository,
<https://github.com/arjaythedev/twelve-dollar-server-challenge>. `lab/macro/k6/realistic.js` is a copy of the challenge's own load
test, `bench/load.js`, at commit `162699aca4d8db710b7f0fa30729d4a626b90297`, with two changes (the think times scaled by an
environment variable, and the k6 options read from the environment); `lab/check.sh` fails on any other difference. The challenge
repository is under the MIT License; the entry has no license file of its own. The license text, as published there:

```text
MIT License

Copyright (c) 2026 arjaythedev and the challenge contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
