// k6 load test — sustained load to watch the Azure LB / ingress spread traffic and the HPA scale out.
// (For a per-replica breakdown use the dashboard or scripts/Test-LoadBalancing.ps1.)
//
//   k6 run -e BASE_URL=http://<azure-lb-ip> loadtest/k6-loadbalancing.js
//   k6 run -e BASE_URL=http://<ip> -e ENDPOINT=work -e MS=150 loadtest/k6-loadbalancing.js   # CPU -> HPA scale-out
//
// Watch scaling in another terminal:
//   kubectl -n load-balancing get hpa,pods -w
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const ENDPOINT = __ENV.ENDPOINT || 'whoami'; // whoami | delay | work
const MS = __ENV.MS || '200';

export const options = {
  // A new TCP connection per VU iteration, so L4 balancers (Azure LB / kube-proxy) see every request.
  noConnectionReuse: __ENV.REUSE !== 'true',
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 20 },
        { duration: '2m', target: 50 },
        { duration: '1m', target: 100 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1500'],
  },
};

export default function () {
  const url = ENDPOINT === 'whoami' ? `${BASE_URL}/api/whoami` : `${BASE_URL}/api/${ENDPOINT}?ms=${MS}`;
  const res = http.get(url);
  check(res, {
    'status 200': (r) => r.status === 200,
    'served by a replica': (r) => !!r.headers['X-Served-By'],
  });
}
