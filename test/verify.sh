#!/usr/bin/env bash
# Smoke-checks a NetBird deployment from outside, through the Gateway.
#   test/verify.sh             real TLS verification (prod certificate)
#   test/verify.sh --insecure  while still on the staging issuer
set -euo pipefail
cd "$(dirname "$0")"
# NETBIRD_DOMAIN overrides the test domain, e.g. to check the rack.
NETBIRD_DOMAIN=${NETBIRD_DOMAIN:-$(yq .domain values.yaml)}
k=(); [[ "${1:-}" == "--insecure" ]] && k=(-k)
base="https://${NETBIRD_DOMAIN}"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. TLS + dashboard
code=$(curl -sS ${k[@]+"${k[@]}"} -o /dev/null -w '%{http_code}' "${base}/") || fail "TLS/connect to ${base}"
[[ "${code}" == 200 ]] || fail "dashboard returned ${code}"
echo "ok   dashboard + TLS"

# 2. OIDC discovery (embedded IdP) via the plain-HTTP Service
iss=$(curl -sS ${k[@]+"${k[@]}"} "${base}/oauth2/.well-known/openid-configuration" | jq -r .issuer)
[[ "${iss}" == "${base}/oauth2" ]] || fail "issuer is '${iss}'"
echo "ok   OIDC issuer"

# 3. gRPC over h2c: a unary call with an empty message (5-byte frame).
#    A misrouted request gets HTML or a 4xx instead of application/grpc.
hdrs=$(printf '\x00\x00\x00\x00\x00' | curl -sS ${k[@]+"${k[@]}"} --http2 -X POST \
  -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
  -D - -o /dev/null "${base}/management.ManagementService/GetServerKey")
grep -qi '^content-type: application/grpc' <<<"${hdrs}" || fail "gRPC not routed: ${hdrs}"
echo "ok   gRPC (h2c)"

# 4. WebSocket upgrade on /relay over HTTP/1.1 -- must reach the
#    plain-HTTP Service (an h2c upstream cannot upgrade).
code=$(curl -sS ${k[@]+"${k[@]}"} --http1.1 -o /dev/null -w '%{http_code}' --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${base}/relay" || true)
[[ "${code}" == 101 ]] || fail "relay WebSocket upgrade returned ${code}"
echo "ok   relay WebSocket"
echo "ALL OK (${base})"
