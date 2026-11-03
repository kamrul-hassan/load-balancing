# Load Balancing Lab — ASP.NET Core 10 · Angular 22 · Docker · Kubernetes · Azure

A small, deliberately transparent app for **seeing** load balancing work. Every API response says which
replica (pod, node) served it, and the Angular dashboard fires traffic and charts how it was spread.

```
                  ┌─────────────── AKS cluster ────────────────────────────────┐
 Browser / k6 ──► │ Path 1: Azure Load Balancer (L4, public IP)                 │
                  │   └─► web Service (LoadBalancer) ─► nginx pods ─► api Service ─► api pods (3–10, HPA)
                  │ Path 2: App Routing ingress (L7, managed ingress-nginx)     │
                  │   ├─► /api ─► api pods directly (per-request round robin)   │
                  │   └─► /    ─► web pods                                      │
                  └─────────────────────────────────────────────────────────────┘
       GitHub Actions ── CI (build/test/validate) ── CD (push to ACR ─► kubectl apply ─► smoke test)
```

## What's inside

| Path | What |
|---|---|
| `src/LoadBalancing.Api` | ASP.NET Core 10 minimal API, no NuGet dependencies, chiseled non-root image |
| `tests/LoadBalancing.Api.Tests` | xUnit + `WebApplicationFactory` integration tests |
| `web/` | Angular 22 (standalone, signals, zoneless) dashboard, served by unprivileged nginx which proxies `/api` |
| `docker-compose.yml` | 3 API replicas + nginx, load balancing on your laptop with no Kubernetes |
| `k8s/base` | Deployments, Services, HPA, PDB, probes, topology spread, graceful drain |
| `k8s/overlays/local` | Docker Desktop / minikube (NodePort 30080) |
| `k8s/overlays/azure` | AKS: public Azure Load Balancer + App Routing ingress |
| `infra/main.bicep` | ACR + AKS (CNI Overlay, autoscaler, app routing, OIDC/workload identity, optional zones) |
| `.github/workflows` | `ci.yml`, `cd.yml`, `infra.yml` |
| `scripts/` | Azure↔GitHub OIDC setup, PowerShell distribution test |
| `loadtest/` | k6 ramp test (drives the HPA) |

### API endpoints

| Endpoint | Purpose |
|---|---|
| `GET /api/whoami` | Pod name, node, IP, request counter, uptime, client/forwarded IP |
| `GET /api/delay?ms=500` | Async wait: concurrency without CPU |
| `GET /api/work?ms=200` | CPU burn: triggers HPA scale-out |
| `POST /api/admin/ready/false` | Fail **this** pod's readiness probe: watch it drain from the load balancer |
| `POST /api/admin/ready/true` | Bring it back |
| `GET /health/live`, `/health/ready` | Kubernetes probes |

Every response carries `X-Served-By: <pod>` (and nginx adds `X-Web-Pod`), so `curl -i` is enough to see the balancer working.

---

## 1. Run locally

**Prereqs:** .NET 10 SDK, Node 22+, Docker Desktop (enable Kubernetes for step 1c), PowerShell 7.

**1a. Dev mode** (hot reload)
```powershell
dotnet run --project src/LoadBalancing.Api        # http://localhost:5195
cd web; npm install; npm start                    # http://localhost:4200 (proxies /api)
```

**1b. Docker Compose: 3 replicas behind nginx**
```powershell
docker compose up --build
# http://localhost:8080  → Send traffic → three bars
docker compose up --scale api=5 -d               # scale and watch new replicas appear
./scripts/Test-LoadBalancing.ps1 -Url http://localhost:8080 -Requests 300
```

**1c. Local Kubernetes** (Docker Desktop Kubernetes)
```powershell
docker compose build                              # produces loadbalancing-api:local / loadbalancing-web:local
kubectl apply -k k8s/overlays/local
kubectl -n load-balancing get pods -o wide
# http://localhost:30080
```
(minikube: `minikube image load loadbalancing-api:local loadbalancing-web:local` and `minikube addons enable metrics-server` first.)

---

## 2. Deploy to Azure

### One-time setup
1. Push this folder to a new GitHub repo.
2. Run the OIDC setup (creates the resource group, an Entra app with federated credentials, and role assignments, then sets GitHub secrets/variables if `gh` is installed):
   ```powershell
   az login
   ./scripts/setup-azure-github-oidc.ps1 -GitHubRepo <owner>/<repo> -ResourceGroup rg-lb-lab -Location southeastasia
   ```
3. In GitHub, create an environment called **production** (add yourself as a required reviewer if you want deploy approvals).
4. **Actions → Infrastructure → Run workflow**: `what-if` first, then `deploy` (≈ 8–10 minutes).
5. Copy the `acrName` from the run summary into repository variable **ACR_NAME**.

| Kind | Name | Value |
|---|---|---|
| Secret | `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | from the setup script |
| Variable | `AZURE_RESOURCE_GROUP` | `rg-lb-lab` |
| Variable | `AKS_CLUSTER_NAME` | `lblab-aks` |
| Variable | `ACR_NAME` | Bicep output, e.g. `lblabacrxxxxxxxx` |

### Every push to `main`
`cd.yml` runs CI → builds both images → pushes `:<git-sha>` and `:latest` to ACR → pins the sha in the
azure overlay → `kubectl apply -k` → waits for rollout → hits the Azure Load Balancer 60 times and **fails the
deploy if fewer than 2 replicas answered**. The distribution is shown in the run summary.

### Get the URLs
```powershell
az aks get-credentials -g rg-lb-lab -n lblab-aks
kubectl -n load-balancing get svc web        # EXTERNAL-IP  → Path 1, Azure Load Balancer (L4)
kubectl -n load-balancing get ingress        # ADDRESS      → Path 2, App Routing ingress (L7)
```

---

## 3. Load-balancing experiments

| # | Try this | What you should see |
|---|---|---|
| 1 | Dashboard → 500 requests, concurrency 20 | Roughly even bars across the 3 API pods (low imbalance %) |
| 2 | `./scripts/Test-LoadBalancing.ps1 -Url http://<LB-IP> -KeepAlive` against the ingress, then compare `/api` via the LB | **L7 ingress** balances per request even on one connection. Pure **L4** balancing is per connection; this app's nginx opens a fresh upstream connection per request so it still spreads |
| 3 | `kubectl -n load-balancing exec deploy/web -- wget -qO- --post-data= http://api:8080/api/admin/ready/false` (repeat until it hits one pod), or `kubectl port-forward pod/<api-pod> 9000:8080` then `curl -X POST localhost:9000/api/admin/ready/false` | That pod goes `0/1 READY`, vanishes from the dashboard within ~3s, liveness stays green so it is **not** restarted |
| 4 | `kubectl -n load-balancing delete pod <api-pod>` while traffic runs | Zero/near-zero errors thanks to `preStop` sleep + readiness + PDB |
| 5 | `k6 run -e BASE_URL=http://<LB-IP> -e ENDPOINT=work -e MS=150 loadtest/k6-loadbalancing.js` and `kubectl -n load-balancing get hpa,pods -w` | HPA scales api 3 → 10; new pods appear as new bars. Cluster autoscaler adds nodes if pods are Pending |
| 6 | Change `externalTrafficPolicy` to `Local` in `k8s/overlays/azure/web-service-loadbalancer.yaml` | Azure LB health probe only passes on nodes running a web pod; real client IP is preserved (`forwardedFor` in `/api/whoami`) |
| 7 | Set `availabilityZones` in `infra/main.bicepparam` | Pods spread across zones via `topologySpreadConstraints` (`kubectl get nodes -L topology.kubernetes.io/zone`) |
| 8 | `kubectl -n load-balancing set image deploy/api api=<acr>/loadbalancing-api:<older-sha>` | Rolling update: `maxUnavailable: 0`, traffic keeps flowing, dashboard shows old/new pods side by side |

### Why distribution is sometimes uneven
- **L4 is connection-based.** Azure Load Balancer hashes the 5-tuple and kube-proxy picks a pod per *connection*. A browser or HttpClient with keep-alive sends many requests over one connection, so they hit the same pod.
- **L7 is request-based.** ingress-nginx (App Routing) talks to pod IPs directly and picks per request.
- Small samples are noisy. Use 300+ requests before judging.

---

## 4. Clean up (stop paying)
```powershell
az group delete -n rg-lb-lab --yes --no-wait
```
Or pause the cluster between sessions: `az aks stop -g rg-lb-lab -n lblab-aks` / `az aks start ...`.
Rough cost while running: 2 × D2s_v5 nodes + Standard LB + Basic ACR. AKS Free tier has no control-plane charge.
