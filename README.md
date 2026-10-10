# k8s-netbird

Self-hosted [NetBird](https://netbird.io) for the homelab: remote access to
the rack LAN from anywhere over a WireGuard mesh.

- **Server:** the combined `netbird-server` image (management, signal,
  relay and STUN in one container).
- **Login:** NetBird's embedded IdP.
- **Ingress:** Envoy Gateway.
- **TLS:** a Let's Encrypt certificate from cert-manager, validated by
  Cloudflare DNS-01.

Design: `docs/superpowers/specs/2026-10-10-netbird-homelab-design.md`.
Test results: `docs/test-log.md`.

## Layout

```
deploy/               kustomize base -- the only thing the rack consumes
  server.yaml         netbird-server, SQLite PVC, http + h2c Services
  stun-service.yaml   3478/udp LoadBalancer
  dashboard.yaml
  gateway.yaml        Gateway, Certificate, HTTPRoute, stream timeouts
  routing-peer.yaml   in-cluster peer that routes the LAN into the mesh
scripts/secrets.sh    Secrets that never go in git (current kubectl context)
test/                 k3d test cluster: up/down, vars, render, verify
```

Per-cluster values are four variables, substituted by Flux `postBuild` on
the rack and by `flux envsubst --strict` in `test/render.sh`:

| Variable | Test | Rack |
|---|---|---|
| `NETBIRD_DOMAIN` | `netbird-test.nordkeel.dk` | `netbird.nordkeel.dk` |
| `CLUSTER_ISSUER` | `letsencrypt-prod` | `letsencrypt-prod` |
| `GATEWAY_CLASS` | `envoy` | `envoy` |
| `CLUSTER_NAME` | `test` | `rack` |

The rack side (pinned commit, values, fixed MetalLB IPs, DDNS) lives in
Sifungurux/homelab, `clusters/rack/`.

## Test cluster

```sh
make up                                   # colima "netbird" + k3d + Envoy Gateway + cert-manager + issuers
CLOUDFLARE_API_TOKEN=... scripts/secrets.sh cloudflare
scripts/secrets.sh server netbird-test.nordkeel.dk
make apply && make verify
# dashboard: claim owner, create a reusable + ephemeral setup key
NB_SETUP_KEY=... scripts/secrets.sh routing-peer && make apply
```

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
- **Laptop IP.** If DHCP changes `192.168.0.18`, update the Cloudflare A
  record, `test/coredns-custom.yaml` and `/etc/hosts`.
- **KUBECONFIG with several entries** makes k3d write no context.
  `test/up.sh` merges into `~/.kube/config` explicitly.
