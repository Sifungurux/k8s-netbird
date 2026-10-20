#!/usr/bin/env bash
# Creates the Secrets that never go in git, against the CURRENT kubectl
# context -- check it says the cluster you mean before running anything.
#
#   secrets.sh cloudflare            cert-manager/cloudflare-api-token  (env CLOUDFLARE_API_TOKEN)
#   secrets.sh server <domain>       netbird/netbird-server-config      (refuses to overwrite)
#   secrets.sh routing-peer          netbird/netbird-routing-peer       (env NB_SETUP_KEY)
#   secrets.sh ddns                  netbird/cloudflare-ddns-token      (env CLOUDFLARE_DDNS_TOKEN)
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
  server)
    domain="${2:?usage: secrets.sh server <domain>}"
    # store.encryptionKey encrypts the database on the PVC. Replacing it
    # leaves every peer, user and key unreadable -- so never overwrite.
    if kubectl -n netbird get secret netbird-server-config >/dev/null 2>&1; then
      echo "netbird/netbird-server-config already exists; refusing to overwrite it." >&2
      echo "Delete it by hand only together with the netbird-data PVC." >&2
      exit 1
    fi
    # A surviving PVC holds a database encrypted with the OLD key: a new key
    # would make it unreadable. Restore the Secret from the backup instead.
    if kubectl -n netbird get pvc netbird-data >/dev/null 2>&1; then
      echo "netbird/netbird-data PVC exists but the Secret is gone; refusing to create a new key." >&2
      echo "Restore netbird-server-config from the LastPass backup, or delete the PVC to start over." >&2
      exit 1
    fi
    ensure_ns netbird
    rand() { openssl rand -base64 32 | tr -d '\n'; }
    tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
    cat >"${tmp}" <<EOF
server:
  listenAddress: ":80"
  exposedAddress: "https://${domain}:443"
  stunPorts: [3478]
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  authSecret: "$(rand)"
  dataDir: "/var/lib/netbird"
  auth:
    issuer: "https://${domain}/oauth2"
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "$(rand)"
    dashboardRedirectURIs:
      - "https://${domain}/nb-auth"
      - "https://${domain}/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"
  store:
    engine: "sqlite"
    encryptionKey: "$(rand)"
EOF
    kubectl -n netbird create secret generic netbird-server-config --from-file=config.yaml="${tmp}"
    echo "Created. Back it up NOW -- without it the database cannot be decrypted:" >&2
    echo "  kubectl -n netbird get secret netbird-server-config -o jsonpath='{.data.config\\.yaml}' | base64 -d" >&2
    echo "  -> LastPass secure note: 'Home\\Servers/netbird-server-config $(kubectl config current-context)'" >&2
    ;;
  routing-peer)
    : "${NB_SETUP_KEY:?set NB_SETUP_KEY (dashboard -> Setup Keys, reusable + ephemeral)}"
    ensure_ns netbird
    kubectl -n netbird create secret generic netbird-routing-peer \
      --from-literal=setup-key="${NB_SETUP_KEY}" --dry-run=client -o yaml | kubectl apply -f -
    ;;
  ddns)
    : "${CLOUDFLARE_DDNS_TOKEN:?set CLOUDFLARE_DDNS_TOKEN (separate token, Zone:DNS:Edit + Zone:Read on nordkeel.dk)}"
    ensure_ns netbird
    kubectl -n netbird create secret generic cloudflare-ddns-token \
      --from-literal=token="${CLOUDFLARE_DDNS_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2
    exit 2
    ;;
esac
