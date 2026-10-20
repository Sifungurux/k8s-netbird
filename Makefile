.PHONY: up down render apply verify
up:      ; test/up.sh
down:    ; test/down.sh
render:  ; helm template netbird chart/netbird -n netbird -f test/values.yaml
apply:   ; helm upgrade --install netbird chart/netbird -n netbird -f test/values.yaml --kube-context k3d-netbird-test
verify:  ; test/verify.sh
