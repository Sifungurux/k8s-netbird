---
title: NetBird PoC
tags: [netbird, poc, networking, kubernetes, zerotrust, wireguard]
created: 2026-04-26
status: planning
---

# NetBird PoC — Project Document

> **Status:** superseded by docs/superpowers/specs/2026-10-10-netbird-homelab-design.md (combined server, embedded IdP, Envoy Gateway).

**FigJam arkitekturdiagram:** [NetBird PoC — Kubernetes Architecture](https://www.figma.com/board/5XHEJ33LbTj1fEycrWgMIt)

---

## 1. Project Overview

NetBird is an open-source, WireGuard-based zero-trust network overlay that replaces traditional VPNs with a peer-to-peer mesh architecture managed by a central control plane.

### 1.1 Goals

- Validate NetBird as a zero-trust remote access solution (VPN replacement)
- Test site-to-site connectivity between different network segments
- Evaluate secure inter-service mesh connectivity between VMs and containers
- Assess Kubernetes-native deployment of the control plane
- Verify SSO/IdP integration via Keycloak (OIDC)

### 1.2 Scope

Self-hosted NetBird stack deployed on Kubernetes, with peer enrollment across Debian servers, macOS, Windows, and Kubernetes pods, across both LAN and NAT/internet topologies.

---

## 2. Architecture Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Control plane | Self-hosted on Kubernetes | Full control, no SaaS dependency |
| Identity Provider | Keycloak 22+ (self-hosted) | OIDC-compliant, supports device auth flow |
| Keycloak deployment | Same Kubernetes cluster as NetBird | Simplifies networking, single cluster to manage |
| Keycloak realm | Dedicated `netbird` realm | Isolation, easy teardown, no future realm pollution |
| Keycloak client type | Public (no client secret) | Required for device authorization grant flow |
| User source | Local Keycloak users | Simplest for PoC; LDAP federation possible later |
| Ingress controller | Traefik | Existing cluster standard |
| TLS | cert-manager + Let's Encrypt | Automated certificate lifecycle |
| Network topology | Mixed (LAN + cross-NAT) | Reflects real-world use case |
| Peer types | Debian, macOS, Windows, K8s pods | Broad platform coverage |
| Datastore (PoC) | SQLite | Simple for PoC — migrate to PostgreSQL for production |

---

## 3. Architecture

### 3.1 Component Overview

| Component | Role | Endpoint |
| --- | --- | --- |
| Management | REST + gRPC API; policy, peer registry | `https://api.netbird.kirk-pedersen.dk` |
| Signal | WireGuard peer signaling (ICE/STUN) | `https://signal.netbird.kirk-pedersen.dk` |
| Dashboard | Web UI for admin | `https://app.netbird.kirk-pedersen.dk` |
| Coturn (RELAY) | TURN relay for NAT-traversal peers | UDP 3478 + 49152-65535 |
| Keycloak | OIDC identity provider | `https://keycloak.netbird.kirk-pedersen.dk` |

### 3.2 Network Exposure Requirements

All of these must be reachable by external peers:

| Port/Proto | Destination | Purpose |
| --- | --- | --- |
| 443/TCP | `api.netbird.kirk-pedersen.dk` | Management API (via Traefik) |
| 443/TCP | `signal.netbird.kirk-pedersen.dk` | Signal server (via Traefik) |
| 443/TCP | `app.netbird.kirk-pedersen.dk` | Dashboard UI (via Traefik) |
| 443/TCP | `keycloak.netbird.kirk-pedersen.dk` | Device auth browser redirect |
| 3478/UDP | Coturn node/LB IP | STUN/TURN |
| 49152-65535/UDP | Coturn node/LB IP | TURN relay media ports |

### 3.3 Peer Types

| Peer Type | Client | Notes |
| --- | --- | --- |
| Debian Linux server | `netbird` (apt) | Primary server peer type |
| macOS (MacBook) | `netbird` (brew) | Developer workstation |
| Windows | `netbird` (MSI) | End-user machines |
| Kubernetes pods | Sidecar or DaemonSet | Service mesh use case |

---

## 4. Zero-Trust Access Model

NetBird implements a zero-trust network access (ZTNA) model. There is no concept of "inside the network" — access is peer-to-peer, policy-driven, and tied to whether a client is actively connected.

### 4.1 How It Works

Every enrolled machine (peer) gets a WireGuard IP in the `100.x.x.x` range. Services on enrolled servers only need to be reachable on that IP — not on the public internet.

| State | Result |
| --- | --- |
| Client connected to NetBird + in the right policy group | Can reach enrolled servers via their WireGuard IP |
| Client disconnects | WireGuard tunnel drops — no route to servers exists |
| Client connected but not in the right group | No route — policy blocks access |

### 4.2 What to Do on the Server Side

1. Enroll the server as a NetBird peer — it gets a WireGuard IP (e.g. `100.64.0.2`)
2. Firewall the server so services only accept connections from the NetBird subnet (`100.64.0.0/10`), or bind services to the WireGuard interface only
3. Keep public internet ports closed — services are only reachable through the mesh

### 4.3 Controlling Access with Policies (Phase 4)

Policies define which peers can reach which peers. The building blocks are:

- **Groups** — logical collections of peers (e.g. `developers`, `servers`, `k8s-pods`)
- **Policies** — rules that allow traffic between groups (e.g. `developers` → `servers` on port 22/443)

A peer not in the right group has no route even if they are connected to the mesh. The guarantee is: **connected + correct group = access. Anything else = no access.**

### 4.4 Peer Types

| Peer | Enrollment | Typical Use |
| --- | --- | --- |
| macOS / Windows workstation | `netbird up --management-url <url>` | Developer access |
| Debian / Linux server | `netbird up --management-url <url>` | Service host — firewall to WireGuard IP only |
| Kubernetes pod | Sidecar or DaemonSet | Service mesh — pod-to-pod access across clusters |

---

## 5. Phase Plan

| Phase | Title | Objective | Status |
| --- | --- | --- | --- |
| Phase 1 | Control Plane Setup | Deploy NetBird on Kubernetes via Helm. Validate pods, ingress, TLS. | Pending |
| Phase 2 | Keycloak OIDC Integration | Deploy Keycloak, create `netbird` realm and client, validate dashboard login. | Pending |
| Phase 3 | Peer Enrollment | Enroll Debian, macOS, Windows, and K8s pod peers. | Pending |
| Phase 4 | Policy & ACL Validation | Define groups/rules. Test direct tunnels vs relay fallback. | Pending |
| Phase 5 | Routing / Exit Node | Configure Linux peer as routing peer for subnet exposure. | Pending |

---

## 5. Phase 1 — Helm Deployment

### 5.1 Helm Repository

```bash
helm repo add netbird https://netbird.io/helm
helm repo update
```

### 5.2 Install Command

```bash
helm install netbird netbird/netbird \
  -n netbird --create-namespace \
  -f netbird-values.yaml
```

### 5.3 Key Configuration Values

| Setting | Value |
| --- | --- |
| Base domain | `netbird.kirk-pedersen.dk` |
| Management endpoint | `https://api.netbird.kirk-pedersen.dk` |
| Signal endpoint | `https://signal.netbird.kirk-pedersen.dk` |
| Dashboard endpoint | `https://app.netbird.kirk-pedersen.dk` |
| Coturn service type | LoadBalancer (UDP — cannot use Traefik ingress) |
| Datastore | SQLite (PoC only) |
| ClusterIssuer | `letsencrypt-prod` |

### 5.4 Post-Install Verification

```bash
# All pods should be Running
kubectl get pods -n netbird

# Ingresses should have an address
kubectl get ingress -n netbird

# TLS certs should be Ready
kubectl get certificate -n netbird

# Get coturn LoadBalancer IP — set as externalIP in values, then helm upgrade
kubectl get svc -n netbird
```

### 5.5 Known Gotchas

- **Coturn uses UDP** — cannot go through Traefik ingress. Needs LoadBalancer or NodePort + dedicated firewall rules.
- **UDP 49152-65535 must be open externally** for TURN relay (NAT traversal).
- **Coturn `externalIP`** must be set to the public LB IP and `helm upgrade` run before peers can use relay.
- **Keycloak must be publicly reachable** for the device auth browser redirect flow.
- **SQLite is not suitable for production** — plan PostgreSQL migration before going live.

---

## 6. Phase 2 — Keycloak Deployment & OIDC Integration

### 6.1 Helm Install

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install keycloak bitnami/keycloak \
  -n keycloak --create-namespace \
  -f keycloak-values.yaml
```

### 6.2 Key Configuration Values

| Setting | Value |
| --- | --- |
| Keycloak URL | `https://keycloak.netbird.kirk-pedersen.dk` |
| Admin UI | `https://keycloak.netbird.kirk-pedersen.dk/admin` |
| Proxy mode | `edge` (TLS terminated at Traefik) |
| Production mode | `true` |
| Database | PostgreSQL (bundled, 2Gi PVC) |

### 6.3 Realm & Client Setup (Manual Steps)

1. Log in to `https://keycloak.netbird.kirk-pedersen.dk/admin`
2. Create realm: **`netbird`**
3. Create client inside `netbird` realm:

| Setting | Value |
| --- | --- |
| Client ID | `netbird` |
| Client type | OpenID Connect |
| Client authentication | OFF (public) |
| Device Authorization Grant | **ON** ← critical for peer CLI enrollment |
| Standard flow | ON |
| Valid Redirect URIs | `https://app.netbird.kirk-pedersen.dk/*` |
| Web Origins | `https://app.netbird.kirk-pedersen.dk` |
| Default scopes | `openid`, `email`, `profile` |

4. Verify OIDC discovery endpoint returns JSON:

```bash
curl -s https://keycloak.netbird.kirk-pedersen.dk/realms/netbird/.well-known/openid-configuration \
  | python3 -m json.tool | head -20
```

Key fields to confirm: `issuer`, `device_authorization_endpoint`, `token_endpoint`

### 6.4 Wire Keycloak into NetBird

Update `netbird-values.yaml`:

```yaml
management:
  oidcConfigEndpoint: "https://keycloak.netbird.kirk-pedersen.dk/realms/netbird/.well-known/openid-configuration"

dashboard:
  authClientId: "netbird"
  authAuthority: "https://keycloak.netbird.kirk-pedersen.dk/realms/netbird"
  useAuth0: false
```

Then apply:

```bash
helm upgrade netbird netbird/netbird \
  -n netbird \
  -f netbird-values.yaml
```

### 6.5 Validation

1. Open `https://app.netbird.kirk-pedersen.dk` → should redirect to Keycloak login
2. Log in with test user → should land on NetBird dashboard
3. Test device auth flow on a peer:

```bash
netbird up --management-url https://api.netbird.kirk-pedersen.dk
# A URL + code will be printed — open in browser and log in via Keycloak
```

### 6.6 Common Pitfalls

| Symptom | Cause | Fix |
| --- | --- | --- |
| Dashboard redirect loops | `proxy: edge` not set | Ensure `proxy: edge` in Keycloak Helm values |
| `invalid_client` error | Wrong Client ID | Confirm `authClientId: netbird` matches Keycloak |
| Device auth code fails | Grant not enabled | Enable Device Authorization Grant on client |
| Token missing email | `email` scope not assigned | Add `email` + `profile` as default scopes |
| CORS errors in browser | Web Origins not set | Add dashboard URL to Web Origins in Keycloak |

---

## 7. Findings & Notes Log

| Date | Phase | Finding / Note |
| --- | --- | --- |
| 2026-04-26 | Planning | PoC scope defined. Self-hosted on Kubernetes, Keycloak IdP, Traefik, cert-manager. |
| 2026-04-26 | Phase 1 | Helm values file generated. Coturn identified as primary firewall challenge (UDP port range). |
| 2026-04-26 | Phase 2 | Keycloak Helm values and realm setup guide generated. Dedicated `netbird` realm recommended. |

---

## 8. Open Questions

| # | Question | Area | Status |
| --- | --- | --- | --- |
| 1 | What is the real base domain for NetBird? | DNS / Infra | **Resolved: netbird.kirk-pedersen.dk** |
| 2 | Will Keycloak be publicly reachable, or is split-horizon DNS in play? | DNS / Network | Open |
| 3 | Does the cluster support LoadBalancer services? If not, NodePort + manual firewall for coturn. | Infra | Open |
| 4 | What is the public IP/hostname for coturn? | Network | Open |
| 5 | Can UDP 3478 and 49152-65535 be opened on the cluster firewall? | Firewall | Open |
| 6 | Sufficient cluster capacity? (~3-4 GB RAM, ~4 CPU cores needed for full stack) | Capacity | Open |
| 7 | Is there a StorageClass for PVCs? (PostgreSQL needs ~2Gi) | Storage | Open |
| 8 | What is the exact ClusterIssuer name? (used in all ingress annotations) | TLS | Open |
| 9 | Keycloak in same namespace as NetBird, or dedicated `keycloak` namespace? | K8s | Open |
| 10 | Target timeline for moving from idea to actual deployment? | Planning | Open |

---

## 9. Pre-Deployment Checklist

### DNS & Domain

- [ ] Choose and delegate base domain (e.g. `netbird.kirk-pedersen.dk`)
- [ ] Create DNS records: `api.`, `signal.`, `app.`, `keycloak.` → cluster ingress IP
- [ ] Decide split-horizon DNS strategy if Keycloak is internal-only
- [ ] Verify DNS resolves from both inside and outside the cluster

### Kubernetes Cluster

- [ ] Confirm Traefik ingress is installed and handling 443/TCP
- [ ] Confirm cert-manager is installed with a working ClusterIssuer (note the exact name)
- [ ] Confirm cluster supports LoadBalancer services (or plan NodePort for coturn)
- [ ] Confirm a StorageClass exists for PVCs
- [ ] Verify ~3-4 GB RAM and ~4 CPU cores free for the full stack

### Network & Firewall

- [ ] Open 443/TCP inbound to cluster ingress IP
- [ ] Open 3478/UDP inbound to coturn node/LB IP
- [ ] Open 49152-65535/UDP inbound to coturn node/LB IP
- [ ] Confirm coturn external IP/hostname is known and reachable from internet
- [ ] Verify Keycloak URL is reachable from end-user browsers

### Secrets & Credentials

- [ ] Generate strong Keycloak admin password (store in password manager)
- [ ] Generate strong Keycloak PostgreSQL password
- [ ] Generate strong coturn TURN secret
- [ ] Consider storing secrets as Kubernetes Secrets rather than plain Helm values
- [ ] Ensure Helm values files with secrets are NOT committed to version control

### Configuration Placeholders to Replace

| File | Placeholder | Replace With |
| --- | --- | --- |
| `netbird-values.yaml` | `netbird.kirk-pedersen.dk` | Real base domain |
| `netbird-values.yaml` | `keycloak.netbird.kirk-pedersen.dk` | Real Keycloak URL |
| `netbird-values.yaml` | `letsencrypt-prod` | Real ClusterIssuer name |
| `netbird-values.yaml` | `CHANGE_ME_STRONG_PASSWORD` | Real coturn TURN secret |
| `netbird-values.yaml` | `externalIP: ""` | Real coturn public IP (after LB provisioned) |
| `keycloak-values.yaml` | `keycloak.netbird.kirk-pedersen.dk` | Real Keycloak domain |
| `keycloak-values.yaml` | `letsencrypt-prod` | Real ClusterIssuer name |
| `keycloak-values.yaml` | `CHANGE_ME_STRONG_ADMIN_PASSWORD` | Real Keycloak admin password |
| `keycloak-values.yaml` | `CHANGE_ME_DB_PASSWORD` | Real PostgreSQL password |
