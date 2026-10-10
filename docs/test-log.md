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
