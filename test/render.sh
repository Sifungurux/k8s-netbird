#!/usr/bin/env bash
# Renders deploy/ exactly as the rack's Flux Kustomization will:
# kustomize build, then Flux's own variable substitution. --strict
# fails on any variable vars.env does not define, instead of rendering
# an empty hostname.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source test/vars.env; set +a
kubectl kustomize deploy | flux envsubst --strict
