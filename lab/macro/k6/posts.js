// Fixed-rate load on GET /posts/<id>: the same arrival rate as fixed-rate.js (same env vars), a different post every time.
//
// The id comes from the iteration's number in the scenario, times a large prime, modulo 500,000, plus 1: a fixed sequence over
// 1 to 500,000 (the seed's post ids) that is the same on every run, spreads over the whole table (the prime is coprime with
// 500,000, so no id repeats before 500,000 requests), and uses no random number. The warm-up and the measured run each start it
// again at the first id.
//
// Env: TARGET_URL (only its scheme, host and port are used: the path is /posts/<id>), RATE, DURATION, PRE_VUS, MAX_VUS.
// A 404 or a 400 counts as a failed request, so the run is INVALID if the server does not know a post of the sequence.
import http from 'k6/http';
import exec from 'k6/execution';

const ORIGIN = (__ENV.TARGET_URL || 'http://127.0.0.1:8080/').match(/^https?:\/\/[^/]+/)[0];
const RATE = Number(__ENV.RATE || 1000);
const PRE_VUS = Number(__ENV.PRE_VUS || Math.max(50, Math.ceil(RATE / 10)));
const POSTS = 500000;
const PRIME = 999983;

export const options = {
  scenarios: {
    fixed_rate: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: PRE_VUS,
      maxVUs: Number(__ENV.MAX_VUS || PRE_VUS),
    },
  },
  discardResponseBodies: true,
};

export default function () {
  const id = ((exec.scenario.iterationInTest * PRIME) % POSTS) + 1;
  http.get(`${ORIGIN}/posts/${id}`);
}
