# k8s-netbird

Self-hosted [NetBird](https://netbird.io) for the homelab: remote access to
the rack LAN from anywhere over a WireGuard mesh.

- **Server:** the combined `netbird-server` image (management, signal,
  relay and STUN in one container).
- **Login:** NetBird's embedded IdP.
- **Ingress:** Envoy Gateway.
- **TLS:** a Let's Encrypt certificate from cert-manager, validated by
  Cloudflare DNS-01.

Design: `docs/superpowers/specs/2026-10-10-netbird-homelab-design.md`;
packaging as a Helm chart: `docs/superpowers/specs/2026-10-20-helm-chart-design.md`.
Test results: `docs/test-log.md`.

## Layout

```
chart/netbird/            the Helm chart -- the only thing the rack consumes
  templates/server.yaml   netbird-server, SQLite PVC, http + h2c Services
  templates/stun-service.yaml  3478/udp LoadBalancer
  templates/dashboard.yaml
  templates/gateway.yaml  Gateway, Certificate, HTTPRoute, stream timeouts
  templates/routing-peer.yaml  in-cluster peer that routes the LAN into the mesh
scripts/secrets.sh        Secrets that never go in git (current kubectl context)
scripts/chart-version-check.sh  CI: chart changes must bump the version
test/                     k3d test cluster: up/down, values.yaml, verify
```

The chart installs as release `netbird` into namespace `netbird`. It does
not create the Namespace or any Secret. Per-cluster values:

| Value | Test (`test/values.yaml`) | Rack |
|---|---|---|
| `domain` | `netbird-test.nordkeel.dk` | `netbird.nordkeel.dk` |
| `clusterIssuer` | `letsencrypt-prod` | `letsencrypt-prod` |
| `gatewayClass` | `envoy` (default) | `envoy` |
| `clusterName` | `test` | `rack` |
| `gateway.serviceAnnotations` | -- | `metallb.io/loadBalancerIPs: 192.168.150.40` |
| `stun.serviceAnnotations` | -- | `metallb.io/loadBalancerIPs: 192.168.150.41` |

`domain`, `clusterIssuer` and `clusterName` are required: a render without
them fails. Image tags are in `chart/netbird/values.yaml`.

The rack side (OCIRepository, HelmRelease with these values, DDNS) lives
in Sifungurux/homelab, `clusters/rack/`.

## Test cluster

```sh
make up                                   # colima "netbird" + k3d + Envoy Gateway + cert-manager + issuers
CLOUDFLARE_API_TOKEN=... scripts/secrets.sh cloudflare
scripts/secrets.sh server netbird-test.nordkeel.dk   # also creates the namespace
make apply && make verify                 # helm upgrade --install; make render = helm template
# dashboard: claim owner, create a reusable + ephemeral setup key with
# auto-group "<cluster>-routers" (e.g. test-routers)
NB_SETUP_KEY=... scripts/secrets.sh routing-peer && make apply
# Networks: set the routing peer to the GROUP <cluster>-routers, not the peer
```

The routing peer keeps its state in an `emptyDir` and enrolls with an
ephemeral key. Every pod restart therefore creates a **new** peer, and the
old one is cleaned up. A Network routed through the individual peer loses
its router on the first reschedule. Routed through the auto-group, the new
peer takes over by itself.

## Releasing

The chart is published to `oci://ghcr.io/sifungurux/charts/netbird`
(public) by `.github/workflows/chart.yaml`.

1. Renovate opens a PR bumping a NetBird image tag in
   `chart/netbird/values.yaml` and the chart `version`: upstream major,
   minor or patch bumps the chart at the same level. `netbird-server` and
   the `netbird` client move together; the dashboard on its own.
2. CI lints and renders the chart, and fails a PR that changes `chart/`
   without raising `version`. A change by hand bumps the patch version.
3. Run the PR on the test cluster (`make apply && make verify`), merge.
4. On merge, CI pushes the new version unless it is already on GHCR.
5. Renovate in homelab opens a PR bumping the HelmRelease's version;
   merging it rolls the rack.

## Cutover from the old kustomize base

Rehearsed on the test cluster 2026-10-20 (`docs/test-log.md`). Needs a
short outage and must be done from the LAN: the routing peer goes down too.

1. Back up `netbird-server-config` and the PVC contents.
2. Remove the old objects but keep the Namespace and `netbird-data` (on the
   rack: remove the Flux Kustomization; both are `prune: disabled`).
3. Hand the PVC to Helm, and on the rack drop Flux's labels:
   ```sh
   kubectl --context <ctx> -n netbird label pvc netbird-data app.kubernetes.io/managed-by=Helm --overwrite
   kubectl --context <ctx> -n netbird annotate pvc netbird-data meta.helm.sh/release-name=netbird meta.helm.sh/release-namespace=netbird --overwrite
   kubectl --context <ctx> -n netbird label pvc netbird-data kustomize.toolkit.fluxcd.io/name- kustomize.toolkit.fluxcd.io/namespace-
   ```
4. Install the chart (`make apply` / the HelmRelease). Check: the PVC is
   bound to the same PV, `/api/instance` still says `"setup_required":false`,
   `make verify` passes (`NETBIRD_DOMAIN=netbird.nordkeel.dk make verify`
   for the rack).

## Gotchas

- **Never overwrite `netbird-server-config`.** Its `store.encryptionKey`
  encrypts the database; `secrets.sh server` refuses on purpose. Back the
  Secret up the moment it is created.
- **One port, two Services.** Port 80 serves gRPC (h2c) and HTTP/1.1
  WebSocket. gRPC routes go to `netbird-server-grpc`, everything else to
  `netbird-server`. An h2c upstream breaks the relay's WebSocket upgrade.
- **Stream timeouts.** Envoy's defaults (15s route, 5m stream idle) cut
  peers' long-lived streams. `BackendTrafficPolicy netbird-streams` disables
  them, and needs an Envoy Gateway that supports `streamIdleTimeout`.
- **Home router DNS.** It strips private answers (DNS-rebind protection)
  and answers SOA queries with nothing.
  - On test: an `/etc/hosts` entry on peers, `test/coredns-custom.yaml`
    for pods, and cert-manager checking DNS-01 against 1.1.1.1.
  - The rack's cert-manager needs the same DNS-01 flags.
- **colima forwards TCP only.** STUN (3478/udp) is not reachable from
  outside the colima VM on the test cluster. The relay over 443 covers it.
  If 443 isn't reachable on the LAN IP either, restart the profile with
  `colima start netbird --network-address`.
- **Laptop IP.** If DHCP changes `192.168.50.138`, update
  `test/coredns-custom.yaml` and `/etc/hosts`. A public A record is not
  needed: the router strips private answers, so nothing on the LAN uses it.
- **KUBECONFIG with several entries** makes k3d write no context.
  `test/up.sh` merges into `~/.kube/config` explicitly.
