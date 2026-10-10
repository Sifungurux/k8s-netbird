# NetBird on the homelab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A combined NetBird control plane with a Let's Encrypt certificate under `nordkeel.dk`. It is proven end-to-end on a k3d test cluster, then wired into the rack's Flux so the rack LAN is reachable from anywhere.

**Architecture:** `k8s-netbird/deploy/` is one kustomize base. Per-cluster values are `${VARS}`, rendered by `flux envsubst --strict` on the test cluster and by Flux `postBuild.substitute` on the rack. Envoy Gateway terminates TLS with a cert-manager certificate issued by Let's Encrypt over Cloudflare DNS-01. STUN gets its own UDP LoadBalancer. `homelab` points a pinned GitRepository at this repo and adds the rack values, ClusterIssuers, fixed MetalLB IPs and a DDNS updater.

**Tech Stack:** NetBird `netbirdio/netbird-server:0.80.0`, `netbirdio/dashboard:v2.94.0`, `netbirdio/netbird:0.80.0` (routing peer). Envoy Gateway v1.9.2 (test). cert-manager v1.19.1 (matches the rack). k3d v5.9 on colima profile `netbird`, k3s `v1.35.8-k3s1` (matches the rack). Flux v2.8. `favonia/cloudflare-ddns:1.17.1`.

**Spec:** `docs/superpowers/specs/2026-10-10-netbird-homelab-design.md`

## Global Constraints

- Hostnames: `netbird-test.nordkeel.dk` (test), `netbird.nordkeel.dk` (rack). Cloudflare records are **DNS-only (grey cloud)**.
- TLS: cert-manager + Let's Encrypt, ACME **DNS-01** with a Cloudflare token scoped to `Zone:DNS:Edit` + `Zone:Read` on `nordkeel.dk` only. Use staging first, then prod. No ACME email (not required, and LE no longer sends expiry mail).
- Base variables: `NETBIRD_DOMAIN`, `CLUSTER_ISSUER`, `GATEWAY_CLASS`, `CLUSTER_NAME`. Nothing else in `deploy/` may contain `${`, because `--strict` fails on unknown variables.
- No secret value is ever committed. Secrets come from `scripts/secrets.sh` against the **current kubectl context**.
- Rack MetalLB IPs: Gateway `192.168.150.40`, STUN `192.168.150.41`. Router forwards: 443/TCP → .40, 3478/UDP → .41. Port 80 is not opened.
- Single replica, `strategy: Recreate`, SQLite on a PVC. No Postgres, no HA.
- Commits: no `Co-Authored-By` trailer (user's global rule). Never commit on `main`. k8s-netbird work goes on `feat/combined-server-homelab`; homelab work goes on a new `feat/netbird` branch cut from `main`.

## Review Focus

1. **Overwriting `netbird-server-config`** (re-running `secrets.sh server`) would replace `store.encryptionKey` and leave the existing database unreadable. The expected behavior is a refusal. Pinned in Task 3, Step 2.
2. **Using the gRPC Service for WebSocket paths.** `/relay` and `/ws-proxy/` must go to the plain-HTTP Service; h2c upstream breaks the WebSocket upgrade. Pinned by `test/verify.sh` relay check (Task 4).
3. **Long-idle gRPC streams.** Envoy's default 15s route timeout and 5m stream-idle timeout would silently cycle peers. Pinned by the 20-minute idle check (Task 5, Step 7).
4. **Rendering with a missing variable.** The expected behavior is a hard failure, not an empty hostname. Pinned by the `--strict` negative check (Task 4, Step 4).
5. **Re-running `test/up.sh` on an existing cluster** must be idempotent and must not wipe NetBird state. Pinned in Task 1, Step 5.

---

## File Structure

```
k8s-netbird/                              (branch feat/combined-server-homelab)
  deploy/kustomization.yaml               lists base resources
  deploy/namespace.yaml                   namespace netbird
  deploy/server.yaml                      PVC + Deployment + Services netbird-server (http), netbird-server-grpc (h2c)
  deploy/stun-service.yaml                Service netbird-stun, LoadBalancer, 3478/UDP
  deploy/dashboard.yaml                   ConfigMap env + Deployment + Service
  deploy/gateway.yaml                     EnvoyProxy + Gateway + Certificate + HTTPRoute + BackendTrafficPolicy
  deploy/routing-peer.yaml                netbird client Deployment
  scripts/secrets.sh                      server | cloudflare | routing-peer | ddns
  test/k3d.yaml                           k3d cluster, Traefik + metrics-server off
  test/up.sh / test/down.sh               test cluster lifecycle (idempotent)
  test/vars.env                           test values for the 4 variables
  test/issuers.yaml                       LE staging + prod ClusterIssuers
  test/render.sh                          kubectl kustomize deploy | flux envsubst --strict
  test/verify.sh                          TLS, OIDC, gRPC, relay, dashboard smoke checks
  docs/test-log.md                        pass/fail record of the spec's test criteria
  README.md, CLAUDE.md, Makefile          rewritten for the new layout
  (deleted) config/, manifests/, docs/keycloak-realm-setup.md, docs/netbird-secrets.md

homelab/                                  (branch feat/netbird)
  clusters/rack/sources/netbird.yaml      GitRepository -> k8s-netbird (ssh, deploy key, pinned commit)
  clusters/rack/releases/netbird.yaml     Flux Kustomization + postBuild + MetalLB patches
  clusters/rack/letsencrypt-issuers.yaml  same two ClusterIssuers as test/issuers.yaml
  clusters/rack/cloudflare-ddns.yaml      DDNS Deployment for netbird.nordkeel.dk
  clusters/rack/kustomization.yaml        add the four files
  README.md                               NetBird section + go-live runbook
```

---

### Task 1: Remove the old PoC and stand up the rack-like test cluster

**Files:**
- Delete: `config/`, `manifests/`, `docs/keycloak-realm-setup.md`, `docs/netbird-secrets.md`, `Makefile`
- Create: `test/k3d.yaml`, `test/up.sh`, `test/down.sh`

**Interfaces:**
- Produces: kube context `k3d-netbird-test`. GatewayClass `envoy` (Accepted). cert-manager v1.19.1 in `cert-manager`. Docker socket at `$HOME/.colima/netbird/docker.sock`.

- [ ] **Step 1: Delete the old PoC files and the stale context**

```bash
cd ~/Development/k8s-netbird
git rm -r -q config manifests docs/keycloak-realm-setup.md docs/netbird-secrets.md Makefile
kubectl config delete-context k3d-netbird-poc || true
```

- [ ] **Step 2: Write `test/k3d.yaml`**

```yaml
# Test cluster for NetBird. Shaped like the rack where it matters:
# no Traefik (the rack routes through Envoy Gateway), same k8s minor.
# k3s ServiceLB stands in for MetalLB, publishing LoadBalancer ports
# on the k3d loadbalancer node, which maps them onto the laptop.
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: netbird-test
servers: 1
agents: 1
image: rancher/k3s:v1.35.8-k3s1
ports:
  - port: 443:443
    nodeFilters: ["loadbalancer"]
  - port: 3478:3478/udp
    nodeFilters: ["loadbalancer"]
options:
  k3s:
    extraArgs:
      - arg: --disable=traefik
        nodeFilters: ["server:*"]
```

- [ ] **Step 3: Write `test/up.sh`**

```bash
#!/usr/bin/env bash
# Brings up the NetBird test cluster: colima profile "netbird", k3d,
# Envoy Gateway, cert-manager and the LE ClusterIssuers. Idempotent --
# every step is create-if-missing or helm upgrade --install, so a re-run
# never touches NetBird's PVC or Secrets.
set -euo pipefail
cd "$(dirname "$0")"

export DOCKER_HOST="unix://${HOME}/.colima/netbird/docker.sock"
colima status netbird >/dev/null 2>&1 || colima start netbird

k3d cluster list netbird-test >/dev/null 2>&1 || k3d cluster create --config k3d.yaml
kubectl config use-context k3d-netbird-test

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 \
  -n envoy-gateway-system --create-namespace --wait --timeout 5m

# The rack's Envoy Gateway install created a GatewayClass named "envoy";
# the base references ${GATEWAY_CLASS}, so the test cluster makes the same one.
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

# Same chart and version the rack's HelmRelease pins.
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io \
  --version v1.19.1 -n cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 5m

kubectl wait --for=condition=Accepted gatewayclass/envoy --timeout=120s

if [[ -f issuers.yaml ]]; then
  kubectl apply -f issuers.yaml
fi
echo "test cluster ready: context k3d-netbird-test"
```

- [ ] **Step 4: Write `test/down.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
export DOCKER_HOST="unix://${HOME}/.colima/netbird/docker.sock"
k3d cluster delete netbird-test
```

- [ ] **Step 5: Run it twice and verify**

```bash
chmod +x test/*.sh
test/up.sh && test/up.sh
kubectl get gatewayclass envoy -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'; echo
kubectl -n cert-manager get deploy
```

Expected:
- Both runs exit 0, and the second run makes no changes.
- The GatewayClass condition prints `True`.
- All three cert-manager deployments show `1/1`.

- [ ] **Step 6: Check that host ports reach the laptop's LAN IP**

Colima's port forwarding decides whether peers can reach the cluster on the LAN IP. Run this with a throwaway LoadBalancer:

```bash
kubectl create deploy probe --image=nginx:alpine --port=80
kubectl expose deploy probe --type=LoadBalancer --port=443 --target-port=80
sleep 15; curl -s -o /dev/null -w '%{http_code}\n' http://$(ipconfig getifaddr en0):443/
kubectl delete svc,deploy probe
```

Expected: `200`.
- If it prints `000`, colima is forwarding to 127.0.0.1 only.
- Then restart the profile with `colima stop netbird && colima start netbird --network-address`, and use `colima ls -p netbird -j | jq -r .address` as the test IP everywhere `en0` is mentioned below.
- Record which IP was used in `docs/test-log.md` (created in Task 5).

- [ ] **Step 7: Commit**

```bash
git add test   # the git rm deletions are already staged
git commit -m "Replace Keycloak/coturn PoC with a rack-like k3d test cluster"
```

---

### Task 2: Let's Encrypt ClusterIssuers over Cloudflare DNS-01

**Files:**
- Create: `test/issuers.yaml`, `scripts/secrets.sh` (`cloudflare` subcommand only for now)

**Interfaces:**
- Consumes: the cert-manager install from Task 1.
- Produces: ClusterIssuers `letsencrypt-staging` and `letsencrypt-prod`. Secret `cert-manager/cloudflare-api-token`, key `api-token`. `scripts/secrets.sh <subcommand>`.

- [ ] **Step 1: Create the Cloudflare token (manual, user)**

In Cloudflare, go to My Profile → API Tokens → Create Token → "Edit zone DNS" template. Set the permissions to `Zone:DNS:Edit` and `Zone:Read`, with Zone Resources limited to **Include → Specific zone → nordkeel.dk**. Store it in 1Password as `cloudflare nordkeel.dk dns-01`.

- [ ] **Step 2: Write `scripts/secrets.sh`**

```bash
#!/usr/bin/env bash
# Creates the Secrets that never go in git, against the CURRENT kubectl
# context -- check it says the cluster you mean before running anything.
#
#   secrets.sh cloudflare            cert-manager/cloudflare-api-token  (env CLOUDFLARE_API_TOKEN)
set -euo pipefail

echo "kubectl context: $(kubectl config current-context)" >&2

ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

case "${1:-}" in
  cloudflare)
    : "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (Zone:DNS:Edit + Zone:Read on nordkeel.dk)}"
    ensure_ns cert-manager
    kubectl -n cert-manager create secret generic cloudflare-api-token \
      --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2
    exit 2
    ;;
esac
```

- [ ] **Step 3: Write `test/issuers.yaml`**

```yaml
# Let's Encrypt over Cloudflare DNS-01: ownership is proven by a TXT
# record, so neither this laptop cluster nor the rack needs port 80
# reachable from the internet. Staging first -- it has no meaningful
# rate limits; prod limits a name to 5 duplicate certs a week.
# homelab/clusters/rack/letsencrypt-issuers.yaml is a copy of this file.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging-account
    solvers:
      - selector:
          dnsZones: ["nordkeel.dk"]
        dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - selector:
          dnsZones: ["nordkeel.dk"]
        dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

- [ ] **Step 4: Apply and verify**

```bash
chmod +x scripts/secrets.sh
scripts/secrets.sh; echo "exit=$?"              # usage, exit 2
CLOUDFLARE_API_TOKEN=$(op read 'op://Private/cloudflare nordkeel.dk dns-01/credential') scripts/secrets.sh cloudflare
kubectl apply -f test/issuers.yaml
kubectl wait --for=condition=Ready clusterissuer/letsencrypt-staging clusterissuer/letsencrypt-prod --timeout=120s
```

Expected:
- The usage text prints with `exit=2`.
- Both ClusterIssuers print `condition met`.

Ready means the ACME account is registered. Actual DNS-01 issuance is proven in Task 4.

- [ ] **Step 5: Commit**

```bash
git add test/issuers.yaml scripts/secrets.sh
git commit -m "Let's Encrypt ClusterIssuers over Cloudflare DNS-01"
```

---

### Task 3: netbird-server with its config Secret

**Files:**
- Create: `deploy/kustomization.yaml`, `deploy/namespace.yaml`, `deploy/server.yaml`, `deploy/stun-service.yaml`, `test/vars.env`, `test/render.sh`
- Modify: `scripts/secrets.sh` (add `server`)

**Interfaces:**
- Consumes: `scripts/secrets.sh` from Task 2.
- Produces:
  - Secret `netbird/netbird-server-config`, key `config.yaml`.
  - Services `netbird-server:80` (http) and `netbird-server-grpc:80` (appProtocol `kubernetes.io/h2c`), both targeting the pod's port `http`.
  - Service `netbird-stun` (LoadBalancer, 3478/UDP).
  - `test/render.sh`, which prints the rendered manifests to stdout.

- [ ] **Step 1: Write the failing check, `test/render.sh` plus `test/vars.env`**

`test/vars.env`:
```bash
NETBIRD_DOMAIN=netbird-test.nordkeel.dk
CLUSTER_ISSUER=letsencrypt-staging
GATEWAY_CLASS=envoy
CLUSTER_NAME=test
```

`test/render.sh`:
```bash
#!/usr/bin/env bash
# Renders deploy/ exactly as the rack's Flux Kustomization will:
# kustomize build, then Flux's own variable substitution. --strict
# fails on any variable vars.env does not define, instead of rendering
# an empty hostname.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source test/vars.env; set +a
kubectl kustomize deploy | flux envsubst --strict
```

Run: `chmod +x test/render.sh && test/render.sh`
Expected: FAIL (`deploy` does not exist yet).

- [ ] **Step 2: Add the `server` subcommand to `scripts/secrets.sh`**

Add this line to the header comment:
```bash
#   secrets.sh server <domain>       netbird/netbird-server-config      (refuses to overwrite)
```

Add this case above `*)`:
```bash
  server)
    domain="${2:?usage: secrets.sh server <domain>}"
    # store.encryptionKey encrypts the database on the PVC. Replacing it
    # leaves every peer, user and key unreadable -- so never overwrite.
    if kubectl -n netbird get secret netbird-server-config >/dev/null 2>&1; then
      echo "netbird/netbird-server-config already exists; refusing to overwrite it." >&2
      echo "Delete it by hand only together with the netbird-data PVC." >&2
      exit 1
    fi
    ensure_ns netbird
    rand() { openssl rand -base64 32 | tr -d '\n'; }
    tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
    cat >"${tmp}" <<EOF
server:
  listenAddress: ":80"
  exposedAddress: "https://${domain}:443"
  stunPorts: [3478]
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  authSecret: "$(rand)"
  dataDir: "/var/lib/netbird"
  auth:
    issuer: "https://${domain}/oauth2"
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "$(rand)"
    dashboardRedirectURIs:
      - "https://${domain}/nb-auth"
      - "https://${domain}/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"
  store:
    engine: "sqlite"
    encryptionKey: "$(rand)"
EOF
    kubectl -n netbird create secret generic netbird-server-config --from-file=config.yaml="${tmp}"
    echo "Created. Back it up NOW -- without it the database cannot be decrypted:" >&2
    echo "  kubectl -n netbird get secret netbird-server-config -o jsonpath='{.data.config\\.yaml}' | base64 -d" >&2
    echo "  -> 1Password: 'netbird-server-config $(kubectl config current-context)'" >&2
    ;;
```

Config keys are copied from upstream `combined/config.yaml.example` and the quickstart's `render_combined_yaml`. The server reads the file verbatim, with no env expansion (`combined/cmd/config.go` `LoadConfig`). That's why the domain and secrets are both rendered here.

- [ ] **Step 3: Write `deploy/namespace.yaml`, `deploy/server.yaml`, `deploy/stun-service.yaml`, `deploy/kustomization.yaml`**

`deploy/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netbird
```

`deploy/server.yaml`:
```yaml
# Combined NetBird server: management, signal, relay and STUN in one
# container (upstream layout since v0.65). Its config.yaml holds secrets
# and is created out-of-band by scripts/secrets.sh -- see that script.
#
# One replica and Recreate: the store is SQLite on a ReadWriteOnce PVC.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbird-data
  namespace: netbird
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netbird-server
  namespace: netbird
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: netbird-server
  template:
    metadata:
      labels:
        app: netbird-server
    spec:
      containers:
        - name: server
          image: netbirdio/netbird-server:0.80.0
          args: ["--config", "/etc/netbird/config.yaml"]
          ports:
            - name: http
              containerPort: 80
            - name: stun
              containerPort: 3478
              protocol: UDP
            - name: health
              containerPort: 9000
          readinessProbe:
            tcpSocket:
              port: health
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: health
            periodSeconds: 20
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /etc/netbird
              readOnly: true
            - name: data
              mountPath: /var/lib/netbird
      volumes:
        - name: config
          secret:
            secretName: netbird-server-config
        - name: data
          persistentVolumeClaim:
            claimName: netbird-data
---
# Port 80 speaks both HTTP/1.1 (REST, OAuth2, WebSocket relay) and h2c
# (gRPC). Envoy picks the upstream protocol per Service, so there are two
# Services in front of the one port: gRPC routes use the h2c one, and
# WebSocket MUST use the plain one -- an h2c upstream breaks the upgrade.
apiVersion: v1
kind: Service
metadata:
  name: netbird-server
  namespace: netbird
spec:
  selector:
    app: netbird-server
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: netbird-server-grpc
  namespace: netbird
spec:
  selector:
    app: netbird-server
  ports:
    - name: grpc
      port: 80
      targetPort: http
      appProtocol: kubernetes.io/h2c
```

`deploy/stun-service.yaml`:
```yaml
# STUN is UDP and cannot go through the Gateway. On the rack, homelab
# patches a fixed MetalLB IP onto this Service so the router's 3478/udp
# forward has a stable target.
apiVersion: v1
kind: Service
metadata:
  name: netbird-stun
  namespace: netbird
spec:
  type: LoadBalancer
  selector:
    app: netbird-server
  ports:
    - name: stun
      port: 3478
      targetPort: stun
      protocol: UDP
```

`deploy/kustomization.yaml`:
```yaml
# NetBird base. Per-cluster values are ${VARS}, substituted by Flux
# postBuild on the rack and by test/render.sh on the test cluster:
#   NETBIRD_DOMAIN  CLUSTER_ISSUER  GATEWAY_CLASS  CLUSTER_NAME
# Nothing else under deploy/ may contain a dollar-brace sequence.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - server.yaml
  - stun-service.yaml
```

- [ ] **Step 4: Render, create the Secret, apply, verify**

```bash
test/render.sh >/dev/null && echo render-ok
scripts/secrets.sh server netbird-test.nordkeel.dk
scripts/secrets.sh server netbird-test.nordkeel.dk; echo "exit=$?"     # must refuse
test/render.sh | kubectl apply --server-side -f -
kubectl -n netbird rollout status deploy/netbird-server --timeout=180s
kubectl -n netbird port-forward svc/netbird-server 8080:80 >/dev/null 2>&1 & pf=$!; sleep 3
curl -s http://localhost:8080/oauth2/.well-known/openid-configuration | jq -r .issuer
kill $pf
kubectl -n netbird get svc netbird-stun
```

Expected:
- `render-ok`.
- The second `secrets.sh server` prints `refusing to overwrite` with `exit=1`.
- The rollout succeeds.
- The issuer prints `https://netbird-test.nordkeel.dk/oauth2`.
- `netbird-stun` has an EXTERNAL-IP.

- [ ] **Step 5: Commit**

```bash
git add deploy test/vars.env test/render.sh scripts/secrets.sh
git commit -m "Combined netbird-server: Deployment, h2c/http Services, STUN LoadBalancer"
```

---

### Task 4: Dashboard, Gateway, certificate and routing

**Files:**
- Create: `deploy/dashboard.yaml`, `deploy/gateway.yaml`, `test/verify.sh`
- Modify: `deploy/kustomization.yaml`

**Interfaces:**
- Consumes: Services from Task 3, ClusterIssuers from Task 2.
- Produces:
  - Gateway `netbird/netbird` and EnvoyProxy `netbird/netbird`. homelab patches `spec.provider.kubernetes.envoyService.annotations` on the EnvoyProxy.
  - Certificate `netbird/netbird-tls`.
  - `test/verify.sh [--insecure]`, which exits non-zero on the first failed check.

- [ ] **Step 1: Write the failing check, `test/verify.sh`**

```bash
#!/usr/bin/env bash
# Smoke-checks a NetBird deployment from outside, through the Gateway.
#   test/verify.sh             real TLS verification (prod certificate)
#   test/verify.sh --insecure  while still on the staging issuer
set -euo pipefail
cd "$(dirname "$0")"
set -a; source vars.env; set +a
k=(); [[ "${1:-}" == "--insecure" ]] && k=(-k)
base="https://${NETBIRD_DOMAIN}"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. TLS + dashboard
code=$(curl -sS ${k[@]+"${k[@]}"} -o /dev/null -w '%{http_code}' "${base}/") || fail "TLS/connect to ${base}"
[[ "${code}" == 200 ]] || fail "dashboard returned ${code}"
echo "ok   dashboard + TLS"

# 2. OIDC discovery (embedded IdP) via the plain-HTTP Service
iss=$(curl -sS ${k[@]+"${k[@]}"} "${base}/oauth2/.well-known/openid-configuration" | jq -r .issuer)
[[ "${iss}" == "${base}/oauth2" ]] || fail "issuer is '${iss}'"
echo "ok   OIDC issuer"

# 3. gRPC over h2c: a unary call with an empty message (5-byte frame).
#    A misrouted request gets HTML or a 4xx instead of application/grpc.
hdrs=$(printf '\x00\x00\x00\x00\x00' | curl -sS ${k[@]+"${k[@]}"} --http2 -X POST \
  -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
  -D - -o /dev/null "${base}/management.ManagementService/GetServerKey")
grep -qi '^content-type: application/grpc' <<<"${hdrs}" || fail "gRPC not routed: ${hdrs}"
echo "ok   gRPC (h2c)"

# 4. WebSocket upgrade on /relay over HTTP/1.1 -- must reach the
#    plain-HTTP Service (an h2c upstream cannot upgrade).
code=$(curl -sS ${k[@]+"${k[@]}"} --http1.1 -o /dev/null -w '%{http_code}' --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${base}/relay" || true)
[[ "${code}" == 101 ]] || fail "relay WebSocket upgrade returned ${code}"
echo "ok   relay WebSocket"
echo "ALL OK (${base})"
```

Run: `chmod +x test/verify.sh && test/verify.sh --insecure`
Expected: `FAIL: TLS/connect` (no Gateway yet, and DNS may not exist yet).

- [ ] **Step 2: DNS record (manual, user)**

In Cloudflare, add an A record `netbird-test` → the test IP from Task 1, Step 6. Set Proxy status to **DNS only**.

```bash
dig +short netbird-test.nordkeel.dk                 # expect the test IP
```

Expected: `dig` prints the test IP.

If `dig` is right but the laptop's resolver returns nothing, the router's DNS-rebind protection is dropping private answers. Add `<test IP> netbird-test.nordkeel.dk` to `/etc/hosts` on each test peer.

- [ ] **Step 3: Write `deploy/dashboard.yaml` and `deploy/gateway.yaml`, then add both to `deploy/kustomization.yaml`**

`deploy/dashboard.yaml`:
```yaml
# Env copied from the upstream quickstart's render_dashboard_env, wired
# to the embedded IdP. TLS terminates at the Gateway, so the dashboard's
# own nginx serves plain HTTP (LETSENCRYPT_DOMAIN=none).
apiVersion: v1
kind: ConfigMap
metadata:
  name: netbird-dashboard
  namespace: netbird
data:
  NETBIRD_MGMT_API_ENDPOINT: https://${NETBIRD_DOMAIN}
  NETBIRD_MGMT_GRPC_API_ENDPOINT: https://${NETBIRD_DOMAIN}
  AUTH_AUDIENCE: netbird-dashboard
  AUTH_CLIENT_ID: netbird-dashboard
  AUTH_CLIENT_SECRET: ""
  AUTH_AUTHORITY: https://${NETBIRD_DOMAIN}/oauth2
  USE_AUTH0: "false"
  AUTH_SUPPORTED_SCOPES: openid profile email groups
  AUTH_REDIRECT_URI: /nb-auth
  AUTH_SILENT_REDIRECT_URI: /nb-silent-auth
  NGINX_SSL_PORT: "443"
  LETSENCRYPT_DOMAIN: none
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netbird-dashboard
  namespace: netbird
spec:
  replicas: 1
  selector:
    matchLabels:
      app: netbird-dashboard
  template:
    metadata:
      labels:
        app: netbird-dashboard
    spec:
      containers:
        - name: dashboard
          image: netbirdio/dashboard:v2.94.0
          envFrom:
            - configMapRef:
                name: netbird-dashboard
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            tcpSocket:
              port: http
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: netbird-dashboard
  namespace: netbird
spec:
  selector:
    app: netbird-dashboard
  ports:
    - name: http
      port: 80
      targetPort: http
```

`deploy/gateway.yaml`:
```yaml
# Own Gateway on the shared "envoy" GatewayClass, so NetBird gets its own
# LoadBalancer IP (the router's 443 forward target) instead of sharing the
# supply-chain-monitor Gateway. The EnvoyProxy exists so homelab can patch
# a fixed MetalLB IP onto the Envoy Service; in the base it changes nothing.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: netbird
  namespace: netbird
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        annotations: {}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: netbird
  namespace: netbird
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: netbird
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: ${NETBIRD_DOMAIN}
      tls:
        mode: Terminate
        certificateRefs:
          - name: netbird-tls
      allowedRoutes:
        namespaces:
          from: Same
---
# Explicit Certificate rather than cert-manager's gateway-shim, which
# would need enableGatewayAPI turned on in the rack's cert-manager.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: netbird-tls
  namespace: netbird
spec:
  secretName: netbird-tls
  dnsNames:
    - ${NETBIRD_DOMAIN}
  issuerRef:
    kind: ClusterIssuer
    name: ${CLUSTER_ISSUER}
---
# Paths from the upstream quickstart's Traefik labels. Longest prefix
# wins, so "/" only catches what the server does not serve.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: netbird
  namespace: netbird
spec:
  parentRefs:
    - name: netbird
  hostnames:
    - ${NETBIRD_DOMAIN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /signalexchange.SignalExchange/
        - path:
            type: PathPrefix
            value: /management.ManagementService/
      backendRefs:
        - name: netbird-server-grpc
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /relay
        - path:
            type: PathPrefix
            value: /ws-proxy/
        - path:
            type: PathPrefix
            value: /api
        - path:
            type: PathPrefix
            value: /oauth2
      backendRefs:
        - name: netbird-server
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: netbird-dashboard
          port: 80
---
# Peers hold management/signal gRPC streams and relay WebSockets open
# indefinitely. Envoy's defaults (15s route timeout, 5m stream idle)
# would cut them and make every peer reconnect in a loop. Upstream's
# Traefik setup disables the equivalent timeouts the same way.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: netbird-streams
  namespace: netbird
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: netbird
  timeout:
    http:
      requestTimeout: 0s
      maxStreamDuration: 0s
      streamIdleTimeout: 0s
```

`deploy/kustomization.yaml` resources become:
```yaml
resources:
  - namespace.yaml
  - server.yaml
  - stun-service.yaml
  - dashboard.yaml
  - gateway.yaml
```

- [ ] **Step 4: Apply on staging and verify**

```bash
# negative: an unset variable must fail the render, not produce an empty hostname
( set -a; source test/vars.env; unset CLUSTER_ISSUER; set +a; kubectl kustomize deploy | flux envsubst --strict >/dev/null ); echo "exit=$?"
test/render.sh | kubectl apply --server-side -f -
kubectl -n netbird wait --for=condition=Ready certificate/netbird-tls --timeout=300s
kubectl -n netbird get secret netbird-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer
kubectl -n netbird get gateway netbird -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'; echo
kubectl -n netbird get btp netbird-streams -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}'; echo
test/verify.sh --insecure
```

Expected:
- The negative render fails with a variable-not-set error and a non-zero `exit`.
- The certificate becomes Ready.
- The issuer contains `(STAGING)`.
- The Gateway shows `True`.
- The BackendTrafficPolicy shows `True`. If it prints anything else, `kubectl -n netbird describe btp netbird-streams` names the rejected field.
- `verify.sh` prints `ALL OK`.

If the certificate sticks on "waiting for DNS propagation", the LAN resolver (DNS filtering) is answering the TXT self-check. Re-run the cert-manager helm install in `test/up.sh` with `--set 'extraArgs={--dns01-recursive-nameservers=1.1.1.1:53,--dns01-recursive-nameservers-only}'`, and add the same `extraArgs` to `values` in `homelab/clusters/rack/releases/cert-manager.yaml` in Task 7.

- [ ] **Step 5: Switch the test cluster to the prod issuer and verify with real TLS**

```bash
sed -i '' 's/^CLUSTER_ISSUER=.*/CLUSTER_ISSUER=letsencrypt-prod/' test/vars.env
kubectl -n netbird delete secret netbird-tls
test/render.sh | kubectl apply --server-side -f -
kubectl -n netbird wait --for=condition=Ready certificate/netbird-tls --timeout=300s
test/verify.sh
```

Expected: `ALL OK`, with no `-k`.

- [ ] **Step 6: Commit**

```bash
git add deploy test/verify.sh test/vars.env
git commit -m "Gateway, LE certificate, routes and stream timeouts; dashboard"
```

---

### Task 5: End-to-end peers on the test cluster

**Files:**
- Create: `docs/test-log.md`
- Create: `deploy/routing-peer.yaml`. Modify: `deploy/kustomization.yaml`, `scripts/secrets.sh` (add `routing-peer`, `ddns`)

**Interfaces:**
- Consumes: the working control plane from Task 4.
- Produces: Deployment `netbird-routing-peer` with hostname `routing-peer-${CLUSTER_NAME}`. Secret `netbird/netbird-routing-peer`, key `setup-key`.

- [ ] **Step 1: Claim the owner and create a setup key (manual, user)**

1. Open `https://netbird-test.nordkeel.dk` and complete the first-run setup. The first user becomes the owner.
2. Go to Setup Keys → Create. Name it `routing-peer-test`, make it **Reusable**, check **Ephemeral peers**, and set the expiry to 30 days. Copy the key.

Ephemeral means a restarted pod's old peer entry is removed automatically after it goes offline, so the routing peer can keep its state in an `emptyDir`.

- [ ] **Step 2: Add the `routing-peer` subcommand to `scripts/secrets.sh`**

Header line:
```bash
#   secrets.sh routing-peer          netbird/netbird-routing-peer       (env NB_SETUP_KEY)
```

Case, above `*)`:
```bash
  routing-peer)
    : "${NB_SETUP_KEY:?set NB_SETUP_KEY (dashboard -> Setup Keys, reusable + ephemeral)}"
    ensure_ns netbird
    kubectl -n netbird create secret generic netbird-routing-peer \
      --from-literal=setup-key="${NB_SETUP_KEY}" --dry-run=client -o yaml | kubectl apply -f -
    ;;
```

Also add the rack-only `ddns` subcommand now, so Task 7 pins one SHA. Header line:
```bash
#   secrets.sh ddns                  netbird/cloudflare-ddns-token      (env CLOUDFLARE_DDNS_TOKEN)
```

Case, above `*)`:
```bash
  ddns)
    : "${CLOUDFLARE_DDNS_TOKEN:?set CLOUDFLARE_DDNS_TOKEN (separate token, Zone:DNS:Edit + Zone:Read on nordkeel.dk)}"
    ensure_ns netbird
    kubectl -n netbird create secret generic cloudflare-ddns-token \
      --from-literal=token="${CLOUDFLARE_DDNS_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
    ;;
```

Check both: `scripts/secrets.sh ddns; echo "exit=$?"` prints the `set CLOUDFLARE_DDNS_TOKEN` error with a non-zero exit.

- [ ] **Step 3: Write `deploy/routing-peer.yaml` and add it to `deploy/kustomization.yaml`**

```yaml
# The NetBird server is not a peer. This pod is: it joins the mesh with a
# setup key, and a NetBird Network (configured in the dashboard) routes
# the cluster's LAN through it, masqueraded. Pod egress to the LAN is
# SNATed to the node by the CNI, so no hostNetwork is needed.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netbird-routing-peer
  namespace: netbird
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: netbird-routing-peer
  template:
    metadata:
      labels:
        app: netbird-routing-peer
    spec:
      containers:
        - name: netbird
          image: netbirdio/netbird:0.80.0
          env:
            - name: NB_MANAGEMENT_URL
              value: https://${NETBIRD_DOMAIN}
            - name: NB_HOSTNAME
              value: routing-peer-${CLUSTER_NAME}
            - name: NB_SETUP_KEY
              valueFrom:
                secretKeyRef:
                  name: netbird-routing-peer
                  key: setup-key
          # ponytail: privileged is the smallest thing that works for one pod --
          # it needs /dev/net/tun and to set net.ipv4.ip_forward for masquerade,
          # which capabilities alone do not grant on containerd. Narrow it to a
          # hostPath /dev/net/tun + allowed sysctl if this pod ever multiplies.
          securityContext:
            privileged: true
          resources:
            requests:
              cpu: 20m
              memory: 64Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: state
              mountPath: /var/lib/netbird
      volumes:
        - name: state
          emptyDir: {}
```

```yaml
resources:
  - namespace.yaml
  - server.yaml
  - stun-service.yaml
  - dashboard.yaml
  - gateway.yaml
  - routing-peer.yaml
```

- [ ] **Step 4: Deploy the routing peer and expose the k3d Docker network**

On macOS the k3d Docker network is not reachable from the host, which makes it an honest stand-in for the rack LAN.

```bash
NB_SETUP_KEY='<key from step 1>' scripts/secrets.sh routing-peer
test/render.sh | kubectl apply --server-side -f -
kubectl -n netbird rollout status deploy/netbird-routing-peer --timeout=120s
kubectl -n netbird logs deploy/netbird-routing-peer | grep -iE '(error|fail).*(/dev/net/tun|ip_forward)|operation not permitted' ; echo "exit=$?"   # expect exit=1: no device/sysctl errors
DOCKER_HOST="unix://${HOME}/.colima/netbird/docker.sock" \
  docker network inspect k3d-netbird-test -f '{{(index .IPAM.Config 0).Subnet}}'
kubectl get node k3d-netbird-test-server-0 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; echo
```

In the dashboard:
1. Go to Networks → Add Network `k3d-lan`.
2. Add a Resource with the subnet printed above.
3. Add a Routing Peer, `routing-peer-test`, with Masquerade on.
4. Add a Policy: All → `k3d-lan`, all protocols.

- [ ] **Step 5: Enroll the laptop and a Lima VM (manual, user -- browser login)**

```bash
netbird profile add nb-test
netbird up --profile nb-test --management-url https://netbird-test.nordkeel.dk   # browser login
limactl start --name nb-peer --tty=false template://debian-12
limactl shell nb-peer -- bash -c 'curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh'
limactl shell nb-peer -- sudo netbird up --management-url https://netbird-test.nordkeel.dk --setup-key '<key from step 1>'
netbird status -d --profile nb-test | grep -E 'nb-peer|routing-peer|Connection type|Relayed'
```

Expected:
- `nb-peer` and `routing-peer-test` show `Status: Connected`.
- Connection type is `P2P` for at least one of them.
- If both are `Relayed`, STUN is not reachable. Check the 3478/udp mapping from Task 1, Step 6, and log it. This doesn't block the task as long as the relayed connections work.

- [ ] **Step 6: Route, relay and persistence checks**

```bash
# routed LAN: the k3d API server answers (401/403 JSON proves reachability)
curl -sk --max-time 5 https://<node InternalIP from step 4>:6443/version | jq -r '.reason // .gitVersion'
# forced relay on the Lima peer
limactl shell nb-peer -- bash -c 'sudo netbird down && sudo NB_FORCE_RELAY=true netbird up --management-url https://netbird-test.nordkeel.dk'
limactl shell nb-peer -- sudo netbird status -d | grep -A3 routing-peer-test
# persistence: restart the server, peers and the owner must survive
kubectl -n netbird delete pod -l app=netbird-server
kubectl -n netbird rollout status deploy/netbird-server --timeout=180s
sleep 30; netbird status --profile nb-test | grep -E 'Management|Signal|Peers count'
```

Expected:
- The curl prints `Unauthorized` or `Forbidden`, or a version string.
- The routing-peer entry shows `Relayed` and `Connected`.
- After the restart, Management and Signal show `Connected`, the peers count is unchanged, and the dashboard login still works.

- [ ] **Step 7: Long-idle stream check**

Start this right after Step 6's server restart, and touch nothing for 20 minutes. Do not use a foreground `sleep`: agent shells cap foreground commands at 10 minutes. Come back later, or wait with a background job.

```bash
kubectl -n netbird get pod -l app=netbird-server -o jsonpath='{.items[0].status.startTime}'; echo   # must be >= 20 min ago
kubectl -n netbird logs deploy/netbird-server --since=20m | grep -ciE 'sync stream closed|peer disconnected|context canceled'
netbird status --profile nb-test | grep -E 'Management|Signal'
```

Expected: a count of `0` (or only lines from deliberate actions), and Management and Signal both `Connected`. A count that grows by peers × 4 means streams are being cut every ~5 minutes. Re-check that `btp/netbird-streams` is Accepted.

- [ ] **Step 8: Record results in `docs/test-log.md`**

```markdown
# Test log — netbird-test.nordkeel.dk

| # | Criterion (spec "Testing") | Result | Notes |
|---|---|---|---|
| 1 | LE staging then prod; verify.sh without -k | | |
| 2 | Dashboard owner claimed via embedded IdP | | |
| 3 | Laptop + Lima peer Connected, P2P | | test IP used: |
| 4 | Forced relay connects | | |
| 5 | Streams survive 20 min idle | | |
| 6 | Route to k3d network via routing-peer-test | | |
| 7 | Server pod restart keeps peers + users | | |
```

Fill in every row from Steps 4–7.

- [ ] **Step 9: Clean up the test peers and commit**

```bash
netbird down --profile nb-test
limactl delete -f nb-peer
git add deploy scripts/secrets.sh docs/test-log.md
git commit -m "Routing peer; record end-to-end test results"
```

---

### Task 6: Docs for the new layout, then push

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/project-document.md` (status header only)
- Create: `Makefile`

- [ ] **Step 1: Write `Makefile`**

```make
.PHONY: up down render apply verify
up:      ; test/up.sh
down:    ; test/down.sh
render:  ; test/render.sh
apply:   ; test/render.sh | kubectl apply --server-side -f -
verify:  ; test/verify.sh
```

- [ ] **Step 2: Rewrite `README.md` and `CLAUDE.md`**

Describe:
- the layout (`deploy/` base with the 4 variables, `test/`, `scripts/secrets.sh`);
- the test flow (`make up`, the `secrets.sh` subcommands, `make apply`, `make verify`);
- the rack wiring (homelab pins a commit of this repo);
- the gotchas: never overwrite `netbird-server-config`, two Services for one port, stream timeouts, DNS-rebind and `/etc/hosts`, the colima `--network-address` fallback.

Remove every Keycloak, coturn and nip.io reference. In `docs/project-document.md`, replace the status block with:
`> **Status:** superseded by docs/superpowers/specs/2026-10-10-netbird-homelab-design.md (combined server, embedded IdP, Envoy Gateway).`

- [ ] **Step 3: Verify that no stale references remain**

```bash
grep -rniE 'keycloak|coturn|nip\.io' --include='*.md' --include='*.yaml' --include='Makefile' . | grep -v 'docs/superpowers\|project-document.md' ; echo "exit=$?"
make render >/dev/null && echo render-ok
```

Expected: `exit=1` (no matches), then `render-ok`.

- [ ] **Step 4: Commit and push, then merge to main**

```bash
git add README.md CLAUDE.md Makefile docs/project-document.md
git commit -m "Docs and Makefile for the combined-server layout"
git push -u origin feat/combined-server-homelab
gh pr create --fill --base main
```

After the merge, record the merge commit SHA. Task 7 pins it:

```bash
git switch main && git pull && git rev-parse HEAD
```

---

### Task 7: Rack wiring in homelab

**Files (repo `~/Development/homelab`, new branch `feat/netbird` from `main`):**
- Create: `clusters/rack/sources/netbird.yaml`, `clusters/rack/releases/netbird.yaml`, `clusters/rack/letsencrypt-issuers.yaml`, `clusters/rack/cloudflare-ddns.yaml`
- Modify: `clusters/rack/kustomization.yaml`, `README.md`

**Interfaces:**
- Consumes: the k8s-netbird `main` SHA from Task 6, Step 4. Object names from Tasks 3–5: `EnvoyProxy/netbird`, `Service/netbird-stun`, namespace `netbird`.
- Produces: Flux Kustomization `flux-system/netbird`.

- [ ] **Step 1: Branch**

```bash
cd ~/Development/homelab && git switch main && git pull && git switch -c feat/netbird
```

- [ ] **Step 2: Write `clusters/rack/sources/netbird.yaml`**

```yaml
# k8s-netbird holds the NetBird manifests (deploy/, a kustomize base with
# ${VARS}); this cluster's values are in ../releases/netbird.yaml. Same
# split as supply-chain-monitor: application there, how the rack runs it here.
#
# k8s-netbird is PRIVATE, so -- like flux-system -- this needs ssh and a
# read-only deploy key, not anonymous HTTPS. See README "NetBird".
#
# Pinned to a commit that passed docs/test-log.md on the test cluster,
# not a branch: the rack only runs what was tested.
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: k8s-netbird
  namespace: flux-system
spec:
  interval: 10m
  url: ssh://git@github.com/Sifungurux/k8s-netbird
  ref:
    commit: <SHA from Task 6, Step 4>
  secretRef:
    name: k8s-netbird-git-auth
  ignore: |
    /*
    !/deploy/
```

- [ ] **Step 3: Write `clusters/rack/releases/netbird.yaml`**

```yaml
# NetBird on the rack: k8s-netbird's deploy/ with the rack's values.
# postBuild.substitute is the same substitution test/render.sh runs with
# `flux envsubst --strict` on the test cluster, so the rack gets exactly
# what was tested with these four values swapped.
#
# The patches pin MetalLB IPs: the router forwards 443/tcp to the
# Gateway (.40) and 3478/udp to STUN (.41), so neither may change on a
# reschedule. They are rack-only (k3s ServiceLB ignores the annotation).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: netbird
  namespace: flux-system
spec:
  interval: 10m
  path: ./deploy
  prune: true
  sourceRef:
    kind: GitRepository
    name: k8s-netbird
  postBuild:
    substitute:
      NETBIRD_DOMAIN: netbird.nordkeel.dk
      CLUSTER_ISSUER: letsencrypt-prod
      GATEWAY_CLASS: envoy
      CLUSTER_NAME: rack
  patches:
    - target:
        kind: EnvoyProxy
        name: netbird
      patch: |
        - op: add
          path: /spec/provider/kubernetes/envoyService/annotations/metallb.io~1loadBalancerIPs
          value: 192.168.150.40
    - target:
        kind: Service
        name: netbird-stun
      patch: |
        - op: add
          path: /metadata/annotations
          value:
            metallb.io/loadBalancerIPs: 192.168.150.41
```

- [ ] **Step 4: Write `clusters/rack/letsencrypt-issuers.yaml`**

Copy `k8s-netbird/test/issuers.yaml` verbatim. Replace its last header comment line with:
`# Copy of k8s-netbird/test/issuers.yaml -- keep the two identical.`

Then add this note after the header:
```yaml
# Lives alongside the self-signed CA the supply-chain-monitor chart
# creates for scm.rack.local; these issuers do not affect it.
```

- [ ] **Step 5: Write `clusters/rack/cloudflare-ddns.yaml`**

```yaml
# The home connection's public IPv4 is dynamic. This keeps
# netbird.nordkeel.dk pointed at it -- DNS-only, never proxied: peers
# need the origin directly for gRPC streams and STUN.
#
# Its token is separate from cert-manager's so either can be revoked
# alone; created by k8s-netbird `scripts/secrets.sh ddns`.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflare-ddns
  namespace: netbird
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudflare-ddns
  template:
    metadata:
      labels:
        app: cloudflare-ddns
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
      containers:
        - name: ddns
          image: favonia/cloudflare-ddns:1.17.1
          env:
            - name: CLOUDFLARE_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflare-ddns-token
                  key: token
            - name: DOMAINS
              value: netbird.nordkeel.dk
            - name: PROXIED
              value: "false"
            - name: IP6_PROVIDER
              value: none
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              memory: 64Mi
```

- [ ] **Step 6: Register in `clusters/rack/kustomization.yaml`**

Append to `resources:`:
```yaml
  # NetBird: manifests from k8s-netbird (sources/netbird.yaml), rack values
  # and fixed MetalLB IPs in releases/netbird.yaml. The issuers are
  # cluster-wide; DDNS keeps the public A record on the home IP.
  - letsencrypt-issuers.yaml
  - sources/netbird.yaml
  - releases/netbird.yaml
  - cloudflare-ddns.yaml
```

Order note: `cloudflare-ddns.yaml` targets namespace `netbird`, which the k8s-netbird Kustomization creates. On the very first reconcile the root Kustomization may fail that one object until `netbird` exists, then it succeeds on the next interval. To avoid the first-run error, create the namespace in the go-live runbook (Step 8) before merging.

- [ ] **Step 7: Validate offline (the rack API is unreachable from off-LAN)**

```bash
kubectl kustomize clusters/rack >/dev/null && echo root-ok
flux build kustomization netbird \
  --path ~/Development/k8s-netbird/deploy \
  --kustomization-file clusters/rack/releases/netbird.yaml --dry-run \
  | grep -E 'netbird\.nordkeel\.dk|letsencrypt-prod|192\.168\.150\.4[01]|routing-peer-rack' | sort -u
```

Expected:
- `root-ok`.
- The build output contains `netbird.nordkeel.dk`, `letsencrypt-prod`, `metallb.io/loadBalancerIPs: 192.168.150.40`, `metallb.io/loadBalancerIPs: 192.168.150.41` and `routing-peer-rack`.
- No `${` remains: `... --dry-run | grep -c '\${'` prints `0`.

- [ ] **Step 8: Add the go-live runbook to `README.md`**

Add a `## NetBird` section with these steps, in order:

```markdown
## NetBird

Manifests live in Sifungurux/k8s-netbird (`deploy/`); this repo pins a
tested commit and supplies the rack's values. Tested first on a k3d
cluster -- see k8s-netbird `docs/test-log.md`.

### Go-live (once, on the home LAN, context `rack`)

1. Check Envoy Gateway is new enough for BackendTrafficPolicy
   `streamIdleTimeout` (v1.9.2 was tested):
   `kubectl -n envoy-gateway-system get deploy envoy-gateway -o jsonpath='{.spec.template.spec.containers[0].image}'`
2. Check .40 and .41 are free: `kubectl get svc -A | grep -E '192\.168\.150\.4[01]'` prints nothing.
3. Deploy key for k8s-netbird:
   ssh-keygen -t ed25519 -N '' -C rack-flux-netbird -f /tmp/rack-netbird
   gh repo deploy-key add /tmp/rack-netbird.pub --repo Sifungurux/k8s-netbird --title rack-flux
   kubectl create secret generic k8s-netbird-git-auth -n flux-system \
     --from-file=identity=/tmp/rack-netbird --from-file=identity.pub=/tmp/rack-netbird.pub \
     --from-file=known_hosts=<(ssh-keyscan github.com 2>/dev/null)
4. Secrets (from k8s-netbird):
   kubectl create namespace netbird
   scripts/secrets.sh cloudflare        # CLOUDFLARE_API_TOKEN
   scripts/secrets.sh ddns              # CLOUDFLARE_DDNS_TOKEN
   scripts/secrets.sh server netbird.nordkeel.dk   # then back it up to 1Password
5. Merge this branch; `flux get kustomizations -A` shows netbird Ready,
   `kubectl -n netbird get certificate` Ready, `kubectl -n netbird logs deploy/cloudflare-ddns` shows the record set.
   Fixed IPs landed (the router forwards point at these):
   `kubectl get svc -A | grep -E '192\.168\.150\.4[01]'` shows the Envoy Service on .40 and netbird-stun on .41.
   Timeouts accepted by the rack's Envoy Gateway (proves the step-1 version is new enough):
   `kubectl -n netbird get btp netbird-streams -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}'` prints True.
6. Router: forward 443/tcp -> 192.168.150.40 and 3478/udp -> 192.168.150.41.
7. NAT loopback: from the LAN, `curl -sS https://netbird.nordkeel.dk/` must work.
   If it times out, the router does not hairpin -- override
   netbird.nordkeel.dk -> 192.168.150.40 in the LAN's DNS.
8. Dashboard: claim owner, create a reusable+ephemeral setup key `routing-peer-rack`,
   then `NB_SETUP_KEY=... scripts/secrets.sh routing-peer`. Networks: `rack-lan`,
   resource 192.168.150.0/24, routing peer `routing-peer-rack`, masquerade, policy owner -> rack-lan.
   `kubectl -n netbird logs deploy/netbird-routing-peer | grep -i connected` -- this pod resolves
   netbird.nordkeel.dk to the PUBLIC IP, so if the router does not hairpin it is the first thing to fail.
9. Prove it from outside: phone on mobile data enrolls and opens a 192.168.150.x
   service; laptop off-LAN runs `kubectl --context rack get nodes`.
```

- [ ] **Step 9: Commit and push (do not merge until the go-live steps 1–4 are done)**

```bash
git add clusters/rack README.md
git commit -m "NetBird on the rack: pinned k8s-netbird, LE issuers, fixed IPs, DDNS"
git push -u origin feat/netbird
gh pr create --fill --base main
```
