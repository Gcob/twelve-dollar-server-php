# The driver bench: PHP's FFI to libsqlite3 against PDO

`lab/micro/benches/feed.php`, one run: image 8.5.13 (SQLite 3.45.1 under PDO and under FFI), JIT on, 5 processes, a VM with no other container,
ns per call of the route (query and JSON), median and spread across the processes. Rows and JSON: `feed-8.5-jit-on.txt`, `feed-8.5-jit-on.json`.
Every case checked its answer against the reference's in the same process. It is a developer's look, not a result: the macro pairs are
`lab/results/`'s.

| route | PDO | FFI | FFI against PDO |
| --- | --- | --- | --- |
| feed, `APP_JSON=encode` | 30,848.7 (29,523.5 .. 31,591.4) | 40,994.6 (40,633.4 .. 43,439.5) | +32.9 % |
| feed, `APP_JSON=sqlite` | 30,677.4 (30,456.3 .. 31,356.8) | 30,728.2 (30,423.6 .. 30,977.0) | +0.2 % (inside the spread) |
| post, `APP_JSON=encode` | 2,443.9 (2,348.1 .. 2,501.7) | 2,958.0 (2,888.7 .. 3,045.2) | +21.0 % |
| post, `APP_JSON=sqlite` | 1,993.8 (1,900.9 .. 2,001.1) | 2,127.0 (2,068.8 .. 2,156.5) | +6.7 % |

The PDO rows reproduce the earlier measurement of the same cases (feed `sqlite` 30,449.9, post `sqlite` 1,998.5; `encode` 30,841.6 and 2,429.7).

## The reading

- **With `APP_JSON=sqlite` the feed is one row of one column, so PDO's per-row work is gone, and FFI does not beat what is left of PDO's layer.**
  The feed is 30,728 against 30,677: the same within the spread. A post is slower on FFI (+133 ns).
- **With `encode` FFI loses by 10 us on a feed:** 20 rows of five columns are about 220 FFI calls (an integer or a text read by its length is one to
  three calls each), at about 50 ns a call, where PDO builds the row array in C.
- **The floor, with no class around the calls** (the `APP_JSON=sqlite` statement on `libsqlite3` through FFI, in the same run):

  | | statement stepped and reset, nothing read | text read too | PDO's route |
  | --- | --- | --- | --- |
  | feed | 30,097.9 | 30,210.6 | 30,677.4 |
  | post | 1,875.4 | 1,903.2 | 1,993.8 |

  PDO's layer over SQLite's own work is 580 ns of a feed (1.9 %) and 118 ns of a post (6.3 %). The best an FFI driver could do, with the three calls
  of a read and nothing else, is 467 ns under PDO on a feed (-1.5 %, and the two spreads touch) and 91 ns on a post (-4.5 %). The driver as written
  (a class holding the handle) adds about 500 ns of its own on a feed to those three calls: the method, the property reads, the `global`.
- **The most FFI could save is under the floor of the step lab:** about 0.4 us of a request that costs about 27 us, with a floor of 0.36 to
  0.52 us per request. So the driver was not taken to the writes (the insert with `RETURNING`, the like and `sqlite3_changes`, health, the group
  commit): `lab/app/sqlite-ffi.php` reads only, and the app boots it only with `APP_DRIVER_BENCH=1`.
