# k8s-netbird

Self-hosted [NetBird](https://netbird.io) zero-trust network on Kubernetes.
WireGuard-based peer-to-peer mesh with Keycloak OIDC, deployed via Helm.

## Stack

| Component | Role |
|---|---|
| NetBird Management | Peer registry + REST/gRPC API |
| NetBird Signal | WireGuard peer signaling |
| NetBird Dashboard | Web UI |
| Coturn | TURN relay for NAT traversal |
| Keycloak | OIDC identity provider |
| cert-manager | TLS certificate lifecycle |

## Quick start (lokal)

```bash
# Forudsætninger: colima, k3d, helm, kubectl
make netbird-start   # Start Colima + k3d cluster
make netbird-all     # Deploy hele stacken
```

Følg derefter `docs/keycloak-realm-setup.md` for at opsætte `netbird` realm og OIDC client.

## Endpoints (lokal — nip.io)

| Service | URL |
|---|---|
| Dashboard | https://app.netbird.172.20.10.2.nip.io |
| Management API | https://api.netbird.172.20.10.2.nip.io |
| Signal | https://signal.netbird.172.20.10.2.nip.io |
| Keycloak | https://keycloak.netbird.172.20.10.2.nip.io |

> IP opdateres i `Makefile` og `config/*-local.yaml` hvis lokal IP skifter.

## Filer

```
config/
  k3d-netbird.yaml           k3d cluster config
  netbird-values-local.yaml  NetBird Helm values (lokal)
  netbird-values.yaml        NetBird Helm values (produktion — netbird.kirk-pedersen.dk)
  keycloak-values-local.yaml Keycloak Helm values (lokal)
  keycloak-values.yaml       Keycloak Helm values (produktion)

docs/
  project-document.md        Arkitekturbeslutninger, fase-plan, open questions
  keycloak-realm-setup.md    Manuel guide til Keycloak realm + OIDC client

Makefile                     Lifecycle targets
```

## FigJam arkitekturdiagram

[NetBird PoC — Kubernetes Architecture](https://www.figma.com/board/5XHEJ33LbTj1fEycrWgMIt)
