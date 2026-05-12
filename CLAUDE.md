# k8s-netbird

Self-hosted NetBird zero-trust network PoC on Kubernetes. WireGuard mesh with Keycloak OIDC, deployed via Helm on k3d/Colima locally and a real cluster in production.

## Project Status

Active PoC — Phase 1 (Keycloak) deployed, manual Keycloak realm setup is the current step before Phase 2 (NetBird).

## Key Facts

- **Local IP**: `192.168.50.57` — update `Makefile` and `config/*-local.yaml` if this changes
- **Ingress**: Traefik (TLS terminated at ingress — Keycloak needs `proxy: edge`)
- **TLS local**: `netbird-root-ca-secret` from `cert-manager` ns, copied to `netbird` ns via `make netbird-ca-copy`
- **Prerequisite**: `k8s-infra` repo must be deployed first (provides cluster, cert-manager, PKI)
- **Keycloak chart**: `codecentric/keycloakx` — NOT bitnami
- **Datastore**: SQLite for PoC only — PostgreSQL migration needed before production

## Deploy Sequence

```
make netbird-phase1          # Repos + CA copy + Keycloak
# MANUAL: create 'netbird' realm + client in Keycloak (docs/keycloak-realm-setup.md)
make netbird-phase2          # NetBird control plane
# Log into dashboard FIRST to claim owner role
```

## Critical Gotchas

- **Coturn is UDP** — cannot go through Traefik, needs LoadBalancer + open UDP 3478 and 49152-65535
- After coturn LB provisions, set `externalIP` in values and `helm upgrade` before peers can use relay
- Keycloak must be publicly reachable for device auth browser redirect
- First dashboard login claims owner role — do it immediately after deploy

## Config Files

| File | Purpose |
|---|---|
| `config/netbird-values-local.yaml` | NetBird Helm values (local) |
| `config/netbird-values.yaml` | NetBird Helm values (production) |
| `config/keycloak-values-local.yaml` | Keycloak Helm values (local, H2 db) |
| `config/keycloak-values.yaml` | Keycloak Helm values (production, PostgreSQL) |
| `config/k3d-netbird.yaml` | k3d cluster config |
| `manifests/keycloak-pvc.yaml` | Keycloak H2 persistent volume |
| `docs/keycloak-realm-setup.md` | Manual Keycloak realm + OIDC client guide |
| `docs/project-document.md` | Full architecture decisions, phase plan, open questions |

## claude-flow Memory

Detailed project knowledge is stored in claude-flow under namespace `k8s-netbird`:
- `k8s-netbird/project-overview` — goals, status, domains
- `k8s-netbird/architecture` — all components, endpoints, namespaces
- `k8s-netbird/deploy-workflow` — Makefile targets, Helm charts, values files
- `k8s-netbird/keycloak-oidc-config` — realm/client settings, pitfalls, wiring
- `k8s-netbird/gotchas` — known issues and non-obvious constraints
