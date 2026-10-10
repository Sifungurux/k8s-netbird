.PHONY: up down render apply verify
up:      ; test/up.sh
down:    ; test/down.sh
render:  ; test/render.sh
apply:   ; test/render.sh | kubectl apply --server-side -f -
verify:  ; test/verify.sh
