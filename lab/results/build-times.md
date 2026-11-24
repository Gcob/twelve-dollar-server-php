# Image build times

The first five rows are the images built before this layer existed. The rows after `8.6 | 97` are the builds with the last layer
(`pcntl`, `sockets`, `event`, Workerman), each from an empty Docker build cache for the PHP and Swoole layers, so each row
includes them: the first `8.5` (130 s) is the layer's first build (the layer alone: 14 s; 12 to 14 s on the other images). The
second `8.5` (0 s) is a rebuild after a change to `php-info` only: every layer before it was reused.

| Date | Variant | Seconds | Docker Desktop |
| --- | --- | --- | --- |
| 2026-11-21 | 8.3-apt | 77 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.3 | 197 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.4 | 168 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.5 | 136 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.6 | 97 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.5 | 130 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.5 | 0 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.6 | 93 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.4 | 166 | Docker Desktop 4.76.0 (228118) |
| 2026-11-21 | 8.3 | 179 | Docker Desktop 4.76.0 (228118) |
| 2026-11-22 | 8.5 | 16 | Docker Desktop 4.76.0 (228118) |
| 2026-11-22 | 8.4 | 15 | Docker Desktop 4.76.0 (228118) |
| 2026-11-22 | 8.3 | 14 | Docker Desktop 4.76.0 (228118) |
| 2026-11-23 | 8.3-apt-tzimpel | 21 | Docker Desktop 4.76.0 (228118) |
