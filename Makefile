# ──────────────────────────────────────────────────────────────────────────────
#  NetBird PoC — Makefile (lokal k3d + Colima)
# ──────────────────────────────────────────────────────────────────────────────

COLIMA_PROFILE   := netbird
CLUSTER_NAME     := netbird-poc
K3D_CONFIG       := config/k3d-netbird.yaml

COLIMA_CPU       := 4
COLIMA_MEMORY    := 6    # GiB
COLIMA_DISK      := 40   # GiB

# Opdater denne hvis din lokale IP skifter
LOCAL_IP         := 192.168.50.57

.DEFAULT_GOAL := help

# ──────────────────────────────────────────────────────────────────────────────
#  Hjælp
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo ""
	@echo "  NetBird PoC — Makefile targets"
	@echo ""
	@echo "  Cluster:"
	@echo "    make netbird-start      Start Colima + opret/genoptag cluster"
	@echo "    make netbird-stop       Suspender cluster + stop Colima"
	@echo "    make netbird-delete     Slet cluster permanent"
	@echo "    make netbird-status     Vis status for cluster og pods"
	@echo ""
	@echo "  Stack:"
	@echo "    make netbird-repos      Tilføj Helm repos"
	@echo "    make netbird-infra      Deploy cert-manager"
	@echo "    make netbird-pki        Bootstrap intern CA (netbird-ca-issuer)"
	@echo "    make netbird-keycloak   Deploy Keycloak"
	@echo "    make netbird-deploy     Deploy NetBird control plane"
	@echo "    make netbird-all        Deploy hele stacken i rækkefølge"
	@echo ""
	@echo "  Endpoints (nip.io — ingen /etc/hosts nødvendigt):"
	@echo "    Dashboard:  https://app.netbird.$(LOCAL_IP).nip.io"
	@echo "    Management: https://api.netbird.$(LOCAL_IP).nip.io"
	@echo "    Signal:     https://signal.netbird.$(LOCAL_IP).nip.io"
	@echo "    Keycloak:   https://keycloak.netbird.$(LOCAL_IP).nip.io"
	@echo ""

# ──────────────────────────────────────────────────────────────────────────────
#  Cluster lifecycle
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-start
netbird-start:
	@echo "→ Starter Colima profil '$(COLIMA_PROFILE)'..."
	@colima status -p $(COLIMA_PROFILE) > /dev/null 2>&1 || \
		colima start \
			--profile $(COLIMA_PROFILE) \
			--cpu $(COLIMA_CPU) \
			--memory $(COLIMA_MEMORY) \
			--disk $(COLIMA_DISK) \
			--runtime docker \
			--network-address
	@echo "→ Opretter/genoptager k3d cluster '$(CLUSTER_NAME)'..."
	@k3d cluster list | grep -q $(CLUSTER_NAME) || \
		k3d cluster create --config $(K3D_CONFIG)
	@k3d cluster start $(CLUSTER_NAME) 2>/dev/null || true
	@k3d kubeconfig merge $(CLUSTER_NAME) --kubeconfig-merge-default
	@kubectl config use-context k3d-$(CLUSTER_NAME)
	@echo "✓ Cluster klar — context: k3d-$(CLUSTER_NAME)"

.PHONY: netbird-stop
netbird-stop:
	@k3d cluster stop $(CLUSTER_NAME) 2>/dev/null || true
	@colima stop -p $(COLIMA_PROFILE) 2>/dev/null || true
	@echo "✓ Stoppet"

.PHONY: netbird-delete
netbird-delete:
	@k3d cluster delete $(CLUSTER_NAME) 2>/dev/null || true
	@colima stop -p $(COLIMA_PROFILE) 2>/dev/null || true
	@echo "✓ Slettet"

.PHONY: netbird-status
netbird-status:
	@echo "── Colima ──────────────────────────────"
	@colima status -p $(COLIMA_PROFILE) 2>/dev/null || echo "  Ikke kørende"
	@echo ""
	@echo "── Nodes ───────────────────────────────"
	@kubectl get nodes -o wide 2>/dev/null || echo "  Cluster ikke tilgængeligt"
	@echo ""
	@echo "── Pods (alle namespaces) ──────────────"
	@kubectl get pods -A 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
#  Helm repos
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-repos
netbird-repos:
	@echo "→ Tilføjer Helm repos..."
	helm repo add netbird     https://netbirdio.github.io/helms
	helm repo add codecentric https://codecentric.github.io/helm-charts
	helm repo add jetstack    https://charts.jetstack.io
	helm repo update
	@echo "✓ Done"

# ──────────────────────────────────────────────────────────────────────────────
#  cert-manager
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-infra
netbird-infra:
	@echo "→ Deployer cert-manager..."
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--set crds.enabled=true \
		--rollback-on-failure \
		--timeout 5m
	@echo "✓ cert-manager klar"

# ──────────────────────────────────────────────────────────────────────────────
#  Intern PKI (selvsigneret CA til lokal TLS)
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-pki
netbird-pki:
	@echo "→ Bootstrap intern CA..."
	kubectl apply -f manifests/pki.yaml
	@echo "→ Venter på Root CA..."
	kubectl wait --for=condition=Ready certificate/netbird-root-ca \
		-n cert-manager --timeout=60s
	@echo "✓ PKI klar — ClusterIssuer: netbird-ca-issuer"

.PHONY: netbird-ca-copy
netbird-ca-copy:
	@echo "→ Kopierer CA cert til netbird namespace..."
	kubectl create namespace netbird --dry-run=client -o yaml | kubectl apply -f -
	kubectl get secret netbird-root-ca-secret -n cert-manager -o json \
		| jq '.metadata.namespace = "netbird" | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp)' \
		| kubectl apply -f -
	@echo "✓ netbird-root-ca-secret tilgængelig i netbird namespace"

# ──────────────────────────────────────────────────────────────────────────────
#  Keycloak
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-keycloak
netbird-keycloak:
	@echo "→ Deployer Keycloak..."
	helm upgrade --install keycloak codecentric/keycloakx \
		--namespace keycloak \
		--create-namespace \
		--values config/keycloak-values-local.yaml \
		--rollback-on-failure \
		--timeout 10m
	@echo "✓ Keycloak klar"
	@echo "  Admin UI: https://keycloak.netbird.$(LOCAL_IP).nip.io/admin"
	@echo "  Næste: følg docs/keycloak-realm-setup.md"

# ──────────────────────────────────────────────────────────────────────────────
#  NetBird control plane
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: netbird-deploy
netbird-deploy:
	@echo "→ Deployer NetBird..."
	helm upgrade --install netbird netbird/netbird \
		--namespace netbird \
		--create-namespace \
		--values config/netbird-values-local.yaml \
		--atomic \
		--timeout 10m
	@echo "✓ NetBird klar"
	@echo "  Dashboard: https://app.netbird.$(LOCAL_IP).nip.io"
	@echo ""
	@echo "  Hent coturn LB IP og kør: make netbird-coturn-upgrade"

.PHONY: netbird-coturn-upgrade
netbird-coturn-upgrade:
	@echo "→ Opdaterer coturn externalIP..."
	@COTURN_IP=$$(kubectl get svc -n netbird -l app.kubernetes.io/component=coturn \
		-o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'); \
	echo "  Coturn IP: $$COTURN_IP"; \
	sed -i '' "s/externalIP: .*/externalIP: \"$$COTURN_IP\"/" config/netbird-values-local.yaml; \
	helm upgrade netbird netbird/netbird \
		--namespace netbird \
		--values config/netbird-values-local.yaml \
		--atomic --timeout 5m
	@echo "✓ Coturn opdateret"

# ──────────────────────────────────────────────────────────────────────────────
#  Deploy i to faser (Keycloak realm skal oprettes manuelt imellem)
# ──────────────────────────────────────────────────────────────────────────────

# Fase 1: infrastruktur + Keycloak — stop her og opret realm manuelt
.PHONY: netbird-phase1
netbird-phase1: netbird-repos netbird-infra netbird-pki netbird-ca-copy netbird-keycloak
	@echo ""
	@echo "✓ Fase 1 færdig — infrastruktur og Keycloak er oppe"
	@echo ""
	@echo "  !! MANUEL HANDLING PÅKRÆVET !!"
	@echo "  Opret 'netbird' realm og client i Keycloak før fase 2:"
	@echo "  Keycloak admin: https://keycloak.netbird.$(LOCAL_IP).nip.io/admin"
	@echo "  Følg: docs/keycloak-realm-setup.md"
	@echo ""
	@echo "  Når realm er oprettet: make netbird-phase2"

# Fase 2: NetBird — kræver at Keycloak realm 'netbird' allerede eksisterer
.PHONY: netbird-phase2
netbird-phase2: netbird-deploy
	@echo ""
	@echo "✓ NetBird PoC deployed!"
	@echo ""
	@echo "  Dashboard:  https://app.netbird.$(LOCAL_IP).nip.io"
	@echo "  Keycloak:   https://keycloak.netbird.$(LOCAL_IP).nip.io/admin"
	@echo ""
	@echo "  Næste trin:"
	@echo "  1. Kør: make netbird-coturn-upgrade"
	@echo "  2. Åbn dashboard og log ind"

# Hurtig genvej — kører begge faser uden pause (kun hvis realm allerede eksisterer)
.PHONY: netbird-all
netbird-all: netbird-phase1 netbird-phase2
