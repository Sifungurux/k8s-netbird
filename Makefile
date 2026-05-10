# ──────────────────────────────────────────────────────────────────────────────
#  NetBird PoC — Makefile
#
#  Prerequisite: k8s-infra must be deployed first.
#  See github.com/Sifungurux/k8s-infra — provides cluster, cert-manager, PKI.
# ──────────────────────────────────────────────────────────────────────────────

LOCAL_IP := 192.168.50.57

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo ""
	@echo "  NetBird PoC — Makefile targets"
	@echo ""
	@echo "  Prerequisite: run 'make all' in k8s-infra first"
	@echo ""
	@echo "  Stack:"
	@echo "    make netbird-repos      Add Helm repos"
	@echo "    make netbird-ca-copy    Copy shared CA cert into netbird namespace"
	@echo "    make netbird-keycloak   Deploy Keycloak"
	@echo "    make netbird-deploy     Deploy NetBird control plane"
	@echo ""
	@echo "  Phased deploy (Keycloak realm must be created between phases):"
	@echo "    make netbird-phase1     Keycloak (then create realm manually)"
	@echo "    make netbird-phase2     NetBird"
	@echo ""
	@echo "  Endpoints:"
	@echo "    Dashboard:  https://app.netbird.$(LOCAL_IP).nip.io"
	@echo "    Management: https://api.netbird.$(LOCAL_IP).nip.io"
	@echo "    Signal:     https://signal.netbird.$(LOCAL_IP).nip.io"
	@echo "    Keycloak:   https://keycloak.netbird.$(LOCAL_IP).nip.io"
	@echo ""

# ──────────────────────────────────────────────────────────────────────────────
#  Helm repos
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-repos
netbird-repos:
	@echo "→ Adding Helm repos..."
	helm repo add netbird     https://netbirdio.github.io/helms
	helm repo add codecentric https://codecentric.github.io/helm-charts
	helm repo update
	@echo "✓ Done"

# ──────────────────────────────────────────────────────────────────────────────
#  Copy shared CA cert into netbird namespace
#  (CA is created by k8s-infra — secret lives in cert-manager namespace)
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-ca-copy
netbird-ca-copy:
	@echo "→ Copying CA cert to netbird namespace..."
	kubectl create namespace netbird --dry-run=client -o yaml | kubectl apply -f -
	kubectl get secret local-root-ca-secret -n cert-manager -o json \
		| jq '.metadata.namespace = "netbird" | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp)' \
		| kubectl apply -f -
	@echo "✓ local-root-ca-secret available in netbird namespace"

# ──────────────────────────────────────────────────────────────────────────────
#  Keycloak
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-keycloak
netbird-keycloak:
	@echo "→ Deploying Keycloak..."
	kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f manifests/keycloak-pvc.yaml
	helm upgrade --install keycloak codecentric/keycloakx \
		--namespace keycloak \
		--create-namespace \
		--values config/keycloak-values-local.yaml \
		--rollback-on-failure \
		--timeout 10m
	@echo "✓ Keycloak ready"
	@echo "  Admin UI: https://keycloak.netbird.$(LOCAL_IP).nip.io/admin"
	@echo "  Next: follow docs/keycloak-realm-setup.md"

# ──────────────────────────────────────────────────────────────────────────────
#  NetBird control plane
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-deploy
netbird-deploy:
	@echo "→ Deploying NetBird..."
	helm upgrade --install netbird netbird/netbird \
		--namespace netbird \
		--create-namespace \
		--values config/netbird-values-local.yaml \
		--rollback-on-failure \
		--timeout 10m
	@echo "✓ NetBird ready"
	@echo "  Dashboard: https://app.netbird.$(LOCAL_IP).nip.io"

# ──────────────────────────────────────────────────────────────────────────────
#  Phased deploy
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-phase1
netbird-phase1: netbird-repos netbird-ca-copy netbird-keycloak
	@echo ""
	@echo "✓ Phase 1 done — Keycloak is up"
	@echo ""
	@echo "  !! MANUAL STEP REQUIRED !!"
	@echo "  Create 'netbird' realm and client in Keycloak before phase 2:"
	@echo "  Keycloak admin: https://keycloak.netbird.$(LOCAL_IP).nip.io/admin"
	@echo "  Follow: docs/keycloak-realm-setup.md"
	@echo ""
	@echo "  When realm is ready: make netbird-phase2"

.PHONY: netbird-phase2
netbird-phase2: netbird-deploy
	@echo ""
	@echo "✓ NetBird PoC deployed!"
	@echo ""
	@echo "  Dashboard:  https://app.netbird.$(LOCAL_IP).nip.io"
	@echo "  Keycloak:   https://keycloak.netbird.$(LOCAL_IP).nip.io/admin"
	@echo ""
	@echo "  Next steps:"
	@echo "  1. Log into dashboard first (claim owner role)"
	@echo "  2. Enroll peers: netbird up --management-url https://api.netbird.$(LOCAL_IP).nip.io"

.PHONY: netbird-all
netbird-all: netbird-phase1 netbird-phase2
