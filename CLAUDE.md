# k8s-netbird

Self-hosted NetBird (combined `netbird-server`, embedded IdP) for the homelab.
See `README.md` for layout and gotchas; the spec and plan are under
`docs/superpowers/`.

## Key facts

- `chart/netbird` is the Helm chart the rack consumes: published to
  `oci://ghcr.io/sifungurux/charts/netbird` on merge, pinned by a HelmRelease
  in Sifungurux/homelab `clusters/rack/`. Per-cluster settings are values
  (`domain`, `clusterIssuer`, `gatewayClass`, `clusterName`, the two
  `serviceAnnotations`); test values are `test/values.yaml`.
  Until the rack cutover (`docs/superpowers/plans/2026-10-20-helm-chart.md`
  Task 5) the rack still runs the old `deploy/` from pinned commit `a241cb8`.
- Every change under `chart/` bumps `version` in `Chart.yaml` (CI enforces:
  `scripts/chart-version-check.sh`). Run `make render` (`helm template`)
  after any change.
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
