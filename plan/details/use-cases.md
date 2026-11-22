# Use cases

Every case comes from the spec (`docs/twelve-dollar-server-challenge.md`, section 5) and the k6 scenario
(`bench/load.js`, section 8). The sequences are in [sequences.md](sequences.md), and the steps they share (S1 to S9)
in [steps.md](steps.md).

## The traffic mix

One k6 virtual user (VU) loops on: feed, pause 3 to 7 s, one post, pause 3 to 8 s, 15 % like, 2 % write, pause 5 to
15 s. That's 2.17 requests per loop of about 20.5 s, so **about 0.106 req/s per user**, 9.45 users per steady req/s
(the leaderboard's ratio is 10.8 because its k6 rate includes the ramps, D40).

| Use case        | Share of requests | Why it matters                                            |
|-----------------|-------------------|-----------------------------------------------------------|
| UC1 Read feed   | 46 %              | The heaviest read: 20 posts, 20 like counts, the biggest JSON |
| UC2 Read post   | 46 %              | Same work as one feed row                                 |
| UC3 Like post   | 6.9 %             | JWT check, then a write that must be committed            |
| UC4 Write post  | 0.9 %             | JWT check, JSON body, validation, a write                 |
| UC5 Health      | 0 % under load    | Startup (healthy in 60 s) and the test suite              |
| UC6 Errors      | 0 % under load    | 42 checks of the test suite, byte for byte                |
| UC0 Connection  | every request     | Where the 71,000 ceiling lives                            |

**In short:** UC1 and UC2 are 92 % of the load. UC0 decides how many users can even connect.

## UC0: a user stays connected

- **Actor:** a k6 VU, which keeps one keep-alive connection for its whole life.
- **Flow:** connect, send a request, get the response, stay idle 3 to 15 s, send the next one on the same socket.
- **Constraint:** in direct mode, one connection per user, so 100,000 users means 100,000 open sockets.
  `LimitNOFILE=65535` is a per-process limit.
- **Success:** no connection refused or reset, no request sent on a socket we just closed.

## UC1: read the feed

- **Request:** `GET /feed`, no auth.
- **Flow:** read the 20 most recent posts (`ORDER BY created_at DESC, id DESC`), with each author's username and
  each post's like count, at the time of the request.
- **Response:** 200, `{"posts":[<post> x 20]}`, keys in the exact order.
- **Success:** identical bytes to `test/golden/feed.json` on a fresh DB.

## UC2: read a post

- **Request:** `GET /posts/:id`, no auth.
- **Flow:** validate `:id` (positive integer), read the post, its author and its like count.
- **Responses:** 200 `{"post":<post>}`, 400 `invalid post id`, 404 `post not found`.

## UC3: like a post

- **Request:** `POST /posts/:id/like`, `Authorization: Bearer <jwt>`.
- **Flow:** verify the JWT first, then validate `:id`, then insert the like, ignoring a duplicate.
- **Responses:** 201 the first time (`already_liked:false`), 200 after (`already_liked:true`), 401, 400, 404.
- **Durability:** the like is committed before the response.

## UC4: write a post

- **Request:** `POST /posts`, `Authorization: Bearer <jwt>`, `{"body":"..."}`.
- **Flow:** verify the JWT, parse the JSON body, trim it, check 1 to 500 characters, insert, return the new row.
- **Responses:** 201 with the post (`like_count:0`, author from the token), 400 for the 3 body errors, 401.
- **Durability:** the post is committed before the response.

## UC5: health check

- **Request:** `GET /health`.
- **Flow:** `SELECT 1`, then the uptime in seconds.
- **Responses:** 200 `{"status":"ok","db":"ok","uptime_s":<int>}`, 503 when SQLite fails.

## UC6: errors

- **Unknown path:** 404 `not found`.
- **Auth before id:** `POST /posts/abc/like` without a token is a 401, with a valid token a 400.
- **Every message is exact**, see the error table of the spec.
