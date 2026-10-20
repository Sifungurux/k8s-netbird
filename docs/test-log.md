# Test log — netbird-test.nordkeel.dk

Run: 2026-10-10, k3d `netbird-test` (k3s v1.35.8, Envoy Gateway v1.9.2,
cert-manager v1.19.1), server 0.80.0, dashboard v2.94.0.
Test IP: 192.168.0.18 (laptop `en0`). The colima `--network-address`
fallback was not needed for TCP.

| # | Criterion (spec "Testing") | Result | Notes |
|---|---|---|---|
| 1 | LE staging then prod; verify.sh without -k | PASS | Staging `(STAGING) Dastardly Durum YR1`, then prod `YR1`. `verify.sh`: dashboard, OIDC issuer, gRPC h2c, relay 101 all ok. `openssl s_client` Verify return code 0. |
| 2 | Dashboard owner claimed via embedded IdP | PASS | First login claimed the owner. Login still works after the server restart (#7). |
| 3 | Laptop + Lima peer Connected, P2P | PASS | laptop <-> nb-peer: P2P. Both peers <-> routing-peer-test: see #4 and the STUN note. |
| 4 | Relay connects | PASS | nb-peer <-> routing-peer-test went Relayed on its own via `rels://netbird-test.nordkeel.dk:443`, ping 0% loss. No forced-relay run was needed. |
| 5 | Streams survive 20 min idle | PASS | 21 min untouched after the restart. 0 `sync stream closed`/`peer disconnected`/`context canceled` lines in the server log. Management and Signal stayed Connected on all three peers. |
| 6 | Route to k3d network via routing-peer-test | PASS | `172.18.0.0/16` (unreachable from the macOS host): `GET https://172.18.0.2:6443/version` timed out before the route existed and returned 401 through it (31 ms, P2P from the laptop). |
| 7 | Server pod restart keeps peers + users | PASS | All peers reconnected unaided, 2/2 each, same NetBird IPs. Route still 401. Dashboard login OK. |

## Findings

- **Home router DNS.** DNS-rebind protection strips private answers, so the
  A record resolves publicly but not on the LAN. The router also answers SOA
  queries with an empty NOERROR. Fixes on test: `/etc/hosts` on the Mac (the
  Lima VM inherits it), `test/coredns-custom.yaml` for pods, and cert-manager
  `--dns01-recursive-nameservers-only --dns01-recursive-nameservers=1.1.1.1:53`.
  **The rack goes through the same router, so its cert-manager needs the same
  flags.**
- **STUN on the test cluster.** 3478/udp is unreachable from outside the colima
  VM, because colima `portForwarder: ssh` forwards TCP only. The STUN server
  answers Binding Success inside the VM (127.0.0.1 and LB IP 172.18.0.3). The
  rack uses MetalLB with no colima, so STUN via the public IP is first proven
  at go-live.
- **Lazy connections.** Peers go `Idle` after inactivity (`Lazy connection:
  true`). Clients on 0.80 wake instantly, e.g. a routed request from nb-peer
  answered in 7 ms. The laptop's 0.70.x client woke the routing peer only
  after a few seconds and a retry. Upgrade laptop clients (`brew upgrade
  netbird`) before relying on this from the road.

## 2026-10-20 — cutover rehearsal: deploy/ → chart/netbird 1.0.0

Same k3d cluster, resumed with the old `deploy/` layout and its data.
Test IP now 192.168.50.138 (`test/coredns-custom.yaml`, `/etc/hosts`).

| # | Step | Result | Notes |
|---|---|---|---|
| 1 | Before: `make verify`, owner, PV | PASS | ALL OK; `/api/instance` `{"setup_required":false}`; PV `pvc-ae07a482-…`; routing peer connected. |
| 2 | Delete old objects except Namespace + PVC (stands in for Flux prune) | PASS | PVC Bound; `netbird-server-config`, `netbird-routing-peer`, `netbird-tls` untouched. |
| 3 | Hand PVC to Helm (managed-by label, release-name/namespace `netbird`) | PASS | |
| 4 | `make apply` | PASS | `STATUS: deployed`, no "cannot be imported". |
| 5 | After: same checks | PASS | Same PV; `setup_required:false`; `make verify` ALL OK; routing peer re-enrolled with its setup key and connected to Management, Signal and Relay. |
| 6 | `helm uninstall` keeps the PVC, reinstall | PASS | "kept due to the resource policy: netbird-data"; reinstall rebinds the same PV; all checks as in #5. |

## 2026-10-20 — rack cutover: deploy/ → chart/netbird 1.0.0

Sifungurux/homelab #13 (remove the Kustomization, own the Namespace) and
#14 (OCIRepository 1.0.0 + HelmRelease), done from the LAN.
Backup beforehand: `netbird-server-config` + PVC tar (`store.db`, `idp.db`,
`events.db`) in `~/Backups/netbird-rack-2026-10-20`.

| # | Check | Result | Notes |
|---|---|---|---|
| 1 | After #13: old objects pruned, PVC/Namespace/Secrets kept | PASS | PV `pvc-2873d075-…` Bound; `cloudflare-ddns` untouched. |
| 2 | PVC handed to Helm, Flux labels removed | PASS | |
| 3 | After #14: HelmRelease Ready | PASS | `Helm install succeeded`, chart `1.0.0@sha256:66064741`. |
| 4 | Same database | PASS | Same PV; `/api/instance` `{"setup_required":false}`. |
| 5 | MetalLB IPs, certificate, stream timeouts | PASS | Envoy `.40`, `netbird-stun` `.41`; `netbird-tls` Ready; `netbird-streams` Accepted. |
| 6 | `NETBIRD_DOMAIN=netbird.nordkeel.dk make verify` | PASS | ALL OK. Routing peer connected to Management and Signal. |
| 7 | Phone on 4G reaches the LAN | pending | Manual. |
