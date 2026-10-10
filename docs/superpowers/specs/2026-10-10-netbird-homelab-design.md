# NetBird on the homelab — design

Date: 2026-10-10 · Status: approved in chat, spec under review

## Goal

Reach the homelab rack (LAN `192.168.150.0/24`) from anywhere through a
self-hosted NetBird control plane running **on the rack**, with a publicly
trusted certificate under `nordkeel.dk` (DNS at Cloudflare). Everything is
proven on a disposable k3d test cluster on the laptop before it touches the
rack.

## Constraints

- Home connection: public IPv4, **dynamic** — port-forwarding works, the A
  record must follow the IP.
- Rack: 6 nodes amd64, Cilium, MetalLB (`192.168.150.32-62`), Longhorn,
  Envoy Gateway (`GatewayClass: envoy`), Flux reconciling the `homelab` repo.
  cert-manager v1.19.1 already installed from `homelab`.
- Laptop: arm64, Docker, k3d. NetBird images are multi-arch.
- Rack API is not reachable from off-LAN today — which is the point.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| NetBird topology | Combined `netbirdio/netbird-server` (management + signal + relay + STUN in one container), v0.80.x | Current upstream layout since v0.65. Coturn is obsolete; relay runs over WebSocket on 443. |
| Packaging | Plain kustomize manifests | The official chart (1.9.0, app 0.46, Aug 2025) only covers the old split layout. |
| Identity | Embedded IdP (Dex), local users | Always on in the combined server, supports device auth for `netbird up`. Drops Keycloak entirely. External IdPs can be added later as connectors. |
| TLS | cert-manager + Let's Encrypt, **ACME DNS-01 via Cloudflare API token** | No inbound port 80 needed, so the NAT'd laptop test cluster gets the same real cert as the rack with an identical issuer. Origin CA (only trusted by Cloudflare's edge) and Tunnel (no UDP/STUN) don't fit a DNS-only service. NetBird's built-in LE needs HTTP-01/TLS-ALPN and terminates TLS in the pod. |
| Cert scope | One hostname per environment, no wildcard: `netbird.nordkeel.dk` (rack), `netbird-test.nordkeel.dk` (test) | The combined server and dashboard share one host via path routing. |
| Cloudflare records | DNS-only (grey cloud) | gRPC streams and STUN/UDP must hit the origin directly. |
| Datastore | SQLite on a PVC (Longhorn on rack, local-path on k3d) | Single user, single replica. Postgres is not needed. |
| Repo split | NetBird manifests in `k8s-netbird`; rack values, issuers and DDNS in `homelab` | Same split as supply-chain-monitor: app there, how this cluster runs it here. |
| DDNS | In-cluster Cloudflare DDNS updater on the rack, own token | Versioned with the rest; router-agnostic. |

## Layout

```
k8s-netbird/
  deploy/                    kustomize base; per-cluster values are ${VARS}
    kustomization.yaml
    namespace.yaml
    server.yaml              Deployment (1 replica, strategy Recreate) + PVC + Service (http 80, appProtocol h2c)
    dashboard.yaml           Deployment + Service
    gateway.yaml             Gateway (HTTPS 443) + Certificate + HTTPRoutes
    stun-service.yaml        Service type LoadBalancer, 3478/UDP
    routing-peer.yaml        netbird client Deployment (NET_ADMIN), setup key from Secret
  test/
    k3d.yaml                 Traefik disabled; 443/tcp and 3478/udp on the loadbalancer
    up.sh                    create k3d, helm-install Envoy Gateway + cert-manager,
                             apply test ClusterIssuers, then
                             kustomize build deploy | flux envsubst --strict | kubectl apply -f -
    down.sh
    vars.env                 test values
    issuers.yaml             LE staging + prod ClusterIssuers (Cloudflare DNS-01)
  scripts/secrets.sh         creates the out-of-band Secrets (never in git)

homelab/clusters/rack/
  sources/netbird.yaml       GitRepository -> k8s-netbird, pinned to a commit
  releases/netbird.yaml      Flux Kustomization, path ./deploy, dependsOn cert-manager,
                             postBuild.substitute = rack values
  letsencrypt-issuers.yaml   LE staging + prod ClusterIssuers (Cloudflare DNS-01)
  cloudflare-ddns.yaml       DDNS updater for netbird.nordkeel.dk
```

`flux envsubst --strict` is the same substitution Flux's `postBuild` runs, so
the test cluster applies byte-for-byte what the rack will get with only the
variables changed. `--strict` fails on an unset variable instead of rendering
an empty string.

The old Keycloak/coturn PoC files (`config/`, `manifests/`, Keycloak docs,
Makefile targets) are removed; git history keeps them.

### Variables

| Variable | Test | Rack |
|---|---|---|
| `NETBIRD_DOMAIN` | `netbird-test.nordkeel.dk` | `netbird.nordkeel.dk` |
| `CLUSTER_ISSUER` | `letsencrypt-staging`, then `letsencrypt-prod` | `letsencrypt-prod` |
| `GATEWAY_CLASS` | `envoy` | `envoy` |
| `CLUSTER_NAME` (routing peer hostname) | `test` | `rack` |

The routed CIDR is not a variable. It is a NetBird Network configured in the dashboard: on test it is the k3d Docker network (unreachable from the macOS host, so it stands in for the rack LAN); on the rack it is `192.168.150.0/24`.

The fixed MetalLB IPs on the rack (`192.168.150.40` Gateway, `.41` STUN) are
rack-only. They go in as Kustomization `patches` in `homelab`: an `EnvoyProxy`
service annotation for the Gateway, and an annotation on the STUN Service. They
are not base variables, because k3d's ServiceLB ignores them.

## Secrets (out-of-band, `scripts/secrets.sh`)

| Secret | Namespace | Contents |
|---|---|---|
| `netbird-server-config` | netbird | `config.yaml` with `authSecret`, store encryption key, `exposedAddress` |
| `netbird-routing-peer` | netbird | setup key (created in the dashboard after first login) |
| `cloudflare-api-token` | cert-manager | token with `Zone:DNS:Edit` + `Zone:Read` on `nordkeel.dk` only |
| `cloudflare-ddns-token` | netbird | separate token, same scope (rack only) |

**Open risk:** if `netbird-server` can't take its non-secret settings from env
vars, the whole `config.yaml` is rendered by `secrets.sh` (domain passed as an
argument) rather than split into a ConfigMap plus Secret. This gets settled
during step 1 of the test.

## Traffic

One hostname. The Gateway terminates TLS with the cert-manager certificate.

| Match | Backend | Notes |
|---|---|---|
| `/management.ManagementService/`, `/signalexchange.SignalExchange/` | server :80 | h2c via Service `appProtocol: kubernetes.io/h2c`; route `timeouts.request: 0s` (Envoy's 15s default kills streams) |
| `/relay`, `/ws-proxy/` | server :80 | WebSocket upgrade (Envoy Gateway allows it by default) |
| `/api`, `/oauth2` | server :80 | plain HTTP |
| `/` | dashboard :80 | |
| UDP 3478 | STUN LoadBalancer | cannot go through a Gateway |

Public exposure (rack): router forwards **443/TCP → 192.168.150.40** and
**3478/UDP → 192.168.150.41**. Port 80 is not needed (DNS-01).

**NAT loopback:** inside the house, `netbird.nordkeel.dk` resolves to the
public IP. Either the router hairpins, or the local DNS overrides the name to
`192.168.150.40`. Check this at go-live.

## Reaching the homelab

The control plane is not a peer. A routing-peer pod (netbird client,
`NET_ADMIN`, setup key) joins as a peer, and a NetBird Network/route advertises
the LAN CIDR through it with masquerade. Cilium SNATs pod egress to the node
LAN. An access policy limits that route to the owner's group.

## Testing

### Test cluster (k3d on the laptop)

DNS: `netbird-test.nordkeel.dk` A → laptop LAN IP, DNS-only. If the router's
DNS rebind protection drops private answers, add an `/etc/hosts` entry on test
peers.

Pass criteria, in order:

1. The Certificate goes Ready from **LE staging**, then from **LE prod**.
   `curl -sS https://netbird-test.nordkeel.dk/` succeeds without `-k`.
2. Dashboard loads and the first login through the embedded IdP claims the owner role.
3. `netbird up --management-url https://netbird-test.nordkeel.dk` enrolls the
   laptop and a Lima VM. `netbird status -d` shows them Connected (P2P).
4. Forced relay (`NB_FORCE_RELAY=true` on one peer) still connects, which proves
   WebSocket relay through the Gateway.
5. The management/signal streams survive > 15 min idle, with no reconnect storm
   in the server log. This proves the timeout handling.
6. Routing peer: the Lima VM reaches a laptop-LAN address through the route.
7. `kubectl delete pod` on the server leaves peers and users intact (PVC).

### Rack go-live

1. Point `homelab` at the passing k8s-netbird commit.
2. Create the Secrets on the rack.
3. Set up the router forwards.
4. The DDNS updater sets the A record to the current public IP.
5. A phone on mobile data enrolls and reaches a `192.168.150.x` service.
6. A laptop off-LAN can `kubectl --context rack get nodes` through the mesh.

## Out of scope

Postgres, HA/multiple replicas, external IdPs/SSO connectors, NetBird reverse
proxy feature, metrics/alerting, backups beyond Longhorn snapshots.
