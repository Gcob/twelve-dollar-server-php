// The bench's own load test, for lab/realistic.sh. Copied from reference/twelve-dollar-server-challenge/bench/load.js (the challenge
// repository, commit 162699aca4d8db710b7f0fa30729d4a626b90297, MIT: see lab/NOTICE.md). Two changes, nothing else, and
// lab/check.sh fails on any other:
//   1. every sleep(x) is sleep(x * THINK_SCALE), THINK_SCALE read from the env (default 1). The harness shortens the think time so
//      that a few thousand VUs offer the request rate the bench's many more offer.
//   2. `options` come from the env (REALISTIC_OPTIONS, a JSON object lab/realistic.sh builds): the stages of its staircase or hold, and the
//      thresholds, including the submetrics per endpoint that k6's own summary needs. The original's `VUS`, `DURATION` and `RAMP_UP`
//      are only read by its options, so they stay here unused.
// --- the original, from here ---
/**
 * The load test. One virtual user (VU) = one person browsing the feed, with think time.
 * A submission's score is the highest VUS that passes a 5-minute hold (see README.md).
 *
 *   k6 run -e VUS=2000 bench/load.js
 *   k6 run -e BASE_URL=http://10.0.0.5 -e VUS=8000 bench/load.js
 *
 * Env: BASE_URL (default http://127.0.0.1:3000), VUS (default 100), DURATION (default 5m),
 *      RAMP_UP (default 60s), TOKENS (default seed/tokens.json).
 *
 * User loop: GET /feed -> think 3-7 s -> GET /posts/:id (one from the feed) -> think 3-8 s
 *   -> like it (15% chance) -> write a post (2% chance) -> idle 5-15 s -> repeat.
 *
 * Pass: p95 < 500 ms, p99 < 1000 ms, under 1% failed requests (k6 exits non-zero on a fail).
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:3000';
const THINK_SCALE = Number(__ENV.THINK_SCALE || 1);
const VUS = Number(__ENV.VUS || 100);
const LIKE_PROB = 0.15;
const POST_PROB = 0.02;
const tokens = new SharedArray('tokens', () => JSON.parse(open(__ENV.TOKENS || '../seed/tokens.json')));

export const options = JSON.parse(__ENV.REALISTIC_OPTIONS);

const between = (lo, hi) => lo + Math.random() * (hi - lo);

export default function () {
  const user = tokens[(__VU - 1) % tokens.length];
  const auth = { headers: { Authorization: `Bearer ${user.token}`, 'Content-Type': 'application/json' } };
  if (__ITER === 0) sleep(between(0, 5) * THINK_SCALE); // spread out VUs that start in the same tick

  const feed = http.get(`${BASE_URL}/feed`, { tags: { name: 'GET /feed' } });
  if (!check(feed, { 'feed 200': (r) => r.status === 200 })) { sleep(between(3, 7) * THINK_SCALE); return; }
  const posts = feed.json('posts');
  const post = posts[Math.floor(Math.random() * posts.length)];
  sleep(between(3, 7) * THINK_SCALE);

  check(http.get(`${BASE_URL}/posts/${post.id}`, { tags: { name: 'GET /posts/:id' } }), { 'post 200': (r) => r.status === 200 });
  sleep(between(3, 8) * THINK_SCALE);

  if (Math.random() < LIKE_PROB) {
    const r = http.post(`${BASE_URL}/posts/${post.id}/like`, null, { ...auth, tags: { name: 'POST /posts/:id/like' } });
    check(r, { 'like 200/201': (r) => r.status === 200 || r.status === 201 });
  }
  if (Math.random() < POST_PROB) {
    const body = JSON.stringify({ body: `${user.username} says hi at ${new Date().toISOString()} (VU ${__VU}, iter ${__ITER})` });
    check(http.post(`${BASE_URL}/posts`, body, { ...auth, tags: { name: 'POST /posts' } }), { 'create 201': (r) => r.status === 201 });
  }
  sleep(between(5, 15) * THINK_SCALE);
}
