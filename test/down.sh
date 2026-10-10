#!/usr/bin/env bash
set -euo pipefail
export DOCKER_HOST="unix://${HOME}/.colima/netbird/docker.sock"
k3d cluster delete netbird-test
