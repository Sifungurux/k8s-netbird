# k8s-netbird

Self-hosted NetBird (combined `netbird-server`, embedded IdP) for the homelab.
See `README.md` for layout and gotchas; the spec and plan are under
`docs/superpowers/`.

## Key facts

- `deploy/` is the kustomize base the rack's Flux consumes (pinned commit,
  from Sifungurux/homelab `clusters/rack/`). Only these variables may appear:
  `NETBIRD_DOMAIN`, `CLUSTER_ISSUER`, `GATEWAY_CLASS`, `CLUSTER_NAME`.
  Run `make render` (`flux envsubst --strict`) after any change.
- Test cluster: context `k3d-netbird-test` on colima profile `netbird`
  (`DOCKER_HOST=unix://$HOME/.colima/netbird/docker.sock`).
  - `make up` is idempotent.
  - `make verify` checks TLS, OIDC, gRPC and relay from outside.
- Always pass `--context` explicitly. The default context is often `rack`.
- Secrets come from `scripts/secrets.sh` only. Tokens live in LastPass
  (`Home\Servers/...`); read them with `lpass show --notes <id>` and pipe them
  into the script, never echo them.
- `netbird-server-config` must never be recreated over an existing PVC: it
  holds the database encryption key.
