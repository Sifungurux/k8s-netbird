#!/usr/bin/env bash
# Temporary (goes with deploy/): proves chart/netbird renders exactly what
# the deploy/ kustomize base renders with test/vars.env, apart from the
# PVC's annotations (Flux prune: disabled there, helm.sh/resource-policy:
# keep here -- checked separately below). Then checks required values and
# the homelab annotation values.
set -euo pipefail
cd "$(dirname "$0")/.."

norm() {
  # Comments, key order and flow/block style differ by tool; content must not.
  yq ea '[.] | sort_by(.kind, .metadata.name) | .[] | (... comments="") | (... style="") | sort_keys(..) | splitDoc'
}

old=$(set -a; . test/vars.env; set +a
  kubectl kustomize deploy | flux envsubst --strict \
    | yq 'select(.kind != "Namespace") | del(select(.kind == "PersistentVolumeClaim").metadata.annotations)' | norm)
new=$(helm template netbird chart/netbird -n netbird -f test/values.yaml \
  | yq 'del(select(.kind == "PersistentVolumeClaim").metadata.annotations)' \
  | norm)
diff -u <(echo "${old}") <(echo "${new}")

[[ $(helm template netbird chart/netbird -f test/values.yaml \
  | yq 'select(.kind == "PersistentVolumeClaim").metadata.annotations."helm.sh/resource-policy"') == keep ]] \
  || { echo "FAIL: PVC lacks resource-policy keep" >&2; exit 1; }

for v in domain clusterIssuer clusterName; do
  if helm template netbird chart/netbird -f test/values.yaml --set "$v=" >/dev/null 2>&1; then
    echo "FAIL: render succeeded without $v" >&2; exit 1
  fi
done

out=$(helm template netbird chart/netbird -n netbird -f test/values.yaml \
  --set-string 'gateway.serviceAnnotations.metallb\.io/loadBalancerIPs=192.168.150.40' \
  --set-string 'stun.serviceAnnotations.metallb\.io/loadBalancerIPs=192.168.150.41')
[[ $(yq 'select(.kind=="EnvoyProxy").spec.provider.kubernetes.envoyService.annotations."metallb.io/loadBalancerIPs"' <<<"${out}") == 192.168.150.40 ]] \
  || { echo "FAIL: EnvoyProxy annotation" >&2; exit 1; }
[[ $(yq 'select(.kind=="Service" and .metadata.name=="netbird-stun").metadata.annotations."metallb.io/loadBalancerIPs"' <<<"${out}") == 192.168.150.41 ]] \
  || { echo "FAIL: netbird-stun annotation" >&2; exit 1; }
echo "render-diff OK"
