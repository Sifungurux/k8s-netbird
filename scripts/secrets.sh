#!/usr/bin/env bash
# Creates the Secrets that never go in git, against the CURRENT kubectl
# context -- check it says the cluster you mean before running anything.
#
#   secrets.sh cloudflare            cert-manager/cloudflare-api-token  (env CLOUDFLARE_API_TOKEN)
set -euo pipefail

echo "kubectl context: $(kubectl config current-context)" >&2

ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

case "${1:-}" in
  cloudflare)
    : "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (Zone:DNS:Edit + Zone:Read on nordkeel.dk)}"
    ensure_ns cert-manager
    kubectl -n cert-manager create secret generic cloudflare-api-token \
      --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2
    exit 2
    ;;
esac
