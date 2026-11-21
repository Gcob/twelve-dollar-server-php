// Fixed-rate load: k6 starts RATE requests per second whatever the server does, so a slow server shows up as latency
// and dropped iterations instead of a lower request rate. Every VU keeps its own keep-alive connection, so the number
// of VUs used is the number of connections open.
//
// Env: TARGET_URL (default http://127.0.0.1:8080/), RATE (req/s, default 1000), DURATION (default 30s),
//      PRE_VUS (VUs started before the test, default 50), MAX_VUS (default 200).
// preAllocatedVUs and maxVUs must be high enough that `dropped_iterations` stays 0 at the requested rate.
import http from 'k6/http';

const TARGET_URL = __ENV.TARGET_URL || 'http://127.0.0.1:8080/';

export const options = {
  scenarios: {
    fixed_rate: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 1000),
      timeUnit: '1s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: Number(__ENV.PRE_VUS || 50),
      maxVUs: Number(__ENV.MAX_VUS || 200),
    },
  },
  // The response body is not read: it costs load-generator CPU and nothing here needs it.
  discardResponseBodies: true,
};

export default function () {
  http.get(TARGET_URL);
}
