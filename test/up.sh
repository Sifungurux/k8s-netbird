# Explicit target: KUBECONFIG often lists several files (one relative),
# and k3d then refuses to pick a default and writes no context at all.
k3d kubeconfig merge netbird-test --output "${HOME}/.kube/config" >/dev/null
#!/usr/bin/env bash
# Brings up the NetBird test cluster: colima profile "netbird", k3d,
# Envoy Gateway, cert-manager and the LE ClusterIssuers. Idempotent --
# every step is create-if-missing or helm upgrade --install, so a re-run
# never touches NetBird's PVC or Secrets.
set -euo pipefail
cd "$(dirname "$0")"

export DOCKER_HOST="unix://${HOME}/.colima/netbird/docker.sock"
colima status netbird >/dev/null 2>&1 || colima start netbird

k3d cluster list netbird-test >/dev/null 2>&1 || k3d cluster create --config k3d.yaml
# Explicit target: KUBECONFIG often lists several files (one relative),
# and k3d then refuses to pick a default and writes no context at all.
k3d kubeconfig merge netbird-test --output "${HOME}/.kube/config" >/dev/null
kubectl config use-context k3d-netbird-test

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 \
  -n envoy-gateway-system --create-namespace --wait --timeout 5m

# The rack's Envoy Gateway install created a GatewayClass named "envoy";
# the base references ${GATEWAY_CLASS}, so the test cluster makes the same one.
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

# Same chart and version the rack's HelmRelease pins.
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io \
  --version v1.19.1 -n cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 5m

kubectl wait --for=condition=Accepted gatewayclass/envoy --timeout=120s

if [[ -f issuers.yaml ]]; then
  kubectl apply -f issuers.yaml
fi
echo "test cluster ready: context k3d-netbird-test"
