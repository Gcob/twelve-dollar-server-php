// Fixed-rate load: k6 starts RATE requests per second whatever the server does, so a slow server shows up as latency
// and dropped iterations instead of a lower request rate. Every VU keeps its own keep-alive connection, and k6 hands
// the iterations to its idle VUs in turn, so the connections open equal the VUs started before the test (not the number
// of iterations in flight).
//
// Env: TARGET_URL (default http://127.0.0.1:8080/), RATE (req/s, default 1000), DURATION (default 30s),
//      PRE_VUS (VUs started before the test, default rate / 10, at least 50), MAX_VUS (default PRE_VUS).
// lab/macro.sh always passes all of them. Keep MAX_VUS equal to PRE_VUS: an extra VU initialized during the run drops
// iterations meanwhile, and the VUs must absorb a stall (rate x stall iterations) or `dropped_iterations` is not 0.
// See "VUs and connections" in lab/README.md.
import http from 'k6/http';

const TARGET_URL = __ENV.TARGET_URL || 'http://127.0.0.1:8080/';
const RATE = Number(__ENV.RATE || 1000);
const PRE_VUS = Number(__ENV.PRE_VUS || Math.max(50, Math.ceil(RATE / 10)));

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
  // The response body is not read: it costs load-generator CPU and nothing here needs it.
  discardResponseBodies: true,
};

export default function () {
  http.get(TARGET_URL);
}
