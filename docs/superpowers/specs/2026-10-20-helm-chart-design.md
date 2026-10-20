# NetBird as a semver'd Helm chart — design

Date: 2026-10-20. Supersedes the "Packaging: plain kustomize manifests" row
of `2026-10-10-netbird-homelab-design.md`.

## Why

Today the rack's Flux consumes `deploy/` (a kustomize base) from a pinned
git commit. Upgrading NetBird means editing image tags here, testing, then
re-pinning a commit SHA in Sifungurux/homelab. Jonas wants to upgrade NetBird
by bumping a chart version in a `HelmRelease`, the same way cert-manager is
already run on the rack.

Wrapping NetBird's official chart is not an option: `netbirdio/netbird`
1.9.0 (app 0.46.0) still only has the old split layout (management / signal
/ relay Deployments, Ingress objects). We run the combined `netbird-server`
0.80.0 with the embedded IdP behind Gateway API. So this repo ships **its own
chart**, no upstream dependency.

## Goals

- A Helm chart `netbird` in this repo, rendering what `deploy/` renders today.
- Published as OCI to `oci://ghcr.io/sifungurux/charts/netbird`.
- Upgrade flow, end to end:
  1. Renovate (in this repo) opens a PR bumping a NetBird image tag in
     `values.yaml` **and** the chart `version` in `Chart.yaml`.
  2. Bump rule (Jonas): **upstream minor → chart minor, upstream patch →
     chart patch.**
  3. On merge to `main`, CI publishes the chart if that version is not on
     GHCR yet.
  4. Renovate (in homelab) opens a PR bumping the `HelmRelease` chart
     version. Jonas merges it; Flux rolls it out.
- The rack moves from the `netbird` Kustomization to an `OCIRepository` +
  `HelmRelease`, keeping the existing database and encryption key.

## Non-goals

- Depending on, or tracking, the upstream `netbirdio/netbird` chart. Revisit
  only if upstream ships a combined-server chart.
- Auto-rollout: the HelmRelease pins an exact version, no ranges.
- Running the k3d test cluster in CI.
- Changing what gets deployed (topology, routes, routing peer behaviour,
  secrets handling). This is a repackaging.

## Anti-goals (failure even if it "works")

- A new empty PVC, or a regenerated `netbird-server-config`. Either loses the
  database (the encryption key in that Secret encrypts it).
- The chart creating or owning `netbird-server-config`, `netbird-routing-peer`
  or the Cloudflare secret. Secrets stay out-of-band in `scripts/secrets.sh`.
- The chart (or a Helm uninstall) deleting the Namespace or the data PVC.
- Chart content changes that ship without a version bump.

## Constraints

- **Values replace the four variables** and the homelab patches:

  | Today | Value (names are the builder's call) |
  |---|---|
  | `NETBIRD_DOMAIN` | `domain` |
  | `CLUSTER_ISSUER` | `clusterIssuer` |
  | `GATEWAY_CLASS` | `gatewayClass` |
  | `CLUSTER_NAME` | `clusterName` |
  | homelab patch on EnvoyProxy | annotations for the Envoy Service (MetalLB `.40`) |
  | homelab patch on `netbird-stun` | annotations for the STUN Service (MetalLB `.41`) |
  | image tags | `netbird-server`, `netbird` (client), `dashboard` tags |

  Required values (`domain`, `clusterIssuer`, `clusterName`) fail the render
  when missing (`required`), same spirit as `flux envsubst --strict`.
- **Image versions.** `netbird-server` and the `netbird` client share a
  version and are bumped together (one Renovate group). The dashboard has its
  own version line and follows the same minor/patch rule independently.
  If both bump in one week they are separate PRs, each bumping the chart.
- **Resource names stay identical** (`netbird-server`, `netbird-server-grpc`,
  `netbird-data`, `netbird-tls`, `netbird`, ...): the out-of-band Secrets,
  README, verify script and the router/MetalLB setup refer to them.
- **The chart does not create the Namespace.** It installs into `netbird`.
  On the rack homelab owns the Namespace (with Flux prune disabled, as today);
  on the test cluster `helm --create-namespace` or `test/up.sh` creates it.
- **The PVC survives Helm.** It carries `helm.sh/resource-policy: keep`.
- **Chart version check in CI.** PRs that change anything under the chart
  without bumping `version` fail. Merges to `main` publish only versions not
  already on GHCR (idempotent re-runs).
- Every gotcha comment in `deploy/*.yaml` (two Services on one port, stream
  timeouts, `externalTrafficPolicy: Local`, routing peer capabilities, ...)
  moves into the templates. They are the reason the manifests look odd.
- `CLAUDE.md`, `README.md`, `Makefile` and `test/` are updated to the chart:
  `make render` = `helm template` with `test/values.yaml`,
  `make apply` = `helm upgrade --install`. `make verify` is unchanged.
- `deploy/` is deleted once the chart is merged; the rack keeps running the
  old pinned commit until cutover, so nothing breaks in between.

## Rack cutover (homelab)

A short outage is fine. **Done from home on the LAN**, not over NetBird: the
routing peer goes down with everything else.

1. Back up `netbird-server-config` (Secret YAML) and the `netbird-data` PVC
   contents (the SQLite store) off-cluster.
2. Make sure the Namespace is declared in homelab (prune disabled) before the
   Kustomization goes away.
3. Remove `releases/netbird.yaml` + `sources/netbird.yaml` (the
   `GitRepository` and its deploy key secret are no longer needed; the
   public chart needs no credentials). Flux
   prunes the Deployments, Services, Gateway etc.; Namespace and PVC stay
   (both `prune: disabled`).
4. Hand the existing PVC to Helm: label `app.kubernetes.io/managed-by=Helm`,
   annotate `meta.helm.sh/release-name` / `meta.helm.sh/release-namespace`
   with the HelmRelease's values, and drop the kustomize ownership labels so
   nothing prunes it later.
5. Add `sources/` `OCIRepository` (or `HelmRepository` type `oci`) and
   `releases/netbird.yaml` `HelmRelease` with the rack values, exact version.
6. `make verify`-equivalent checks against `netbird.nordkeel.dk`, plus a peer
   off-LAN (phone on 4G) reaching the LAN through the routing peer.
7. Add homelab Renovate config so the HelmRelease version gets PRs.

`releases/netbird-rack.yaml` has `dependsOn: netbird` (a Kustomization). It
must be repointed or dropped; Kustomization `dependsOn` cannot wait on a
HelmRelease (see the old spec). The builder decides which.

The test cluster rehearses the same cutover first: run the current `deploy/`,
create a peer, then switch to the chart and confirm the peer and its account
are still there.

## Decided by Jonas

- Own chart, OCI on GHCR (not tagged kustomize, not upstream chart).
- Renovate bumps image tags and chart version here; CI publishes on merge.
- Minor follows minor, patch follows patch.
- Renovate PR in homelab, merged by hand; no version ranges.
- Short outage for the cutover, done from home.
- The GHCR chart package is **public** (the repo stays private). No pull
  secret on the rack's `OCIRepository`, no registry credentials for Renovate.
  The publish workflow (or a one-time manual step) must set the package
  visibility to public; new GHCR packages start private.
- Renovate is the **hosted Renovate GitHub App** (Mend), installed on both
  repos; config is a `renovate.json` per repo, no Renovate workflow or token.

## My calls (Claude), to check

- Dashboard bumps follow the same rule on their own.
- Lint/template in CI; the k3d `make verify` stays a manual pre-merge step.
- PVC adopted by Helm via labels/annotations, kept with `resource-policy: keep`.
- Chart doesn't own the Namespace.
- Starting chart version: `1.0.0` (first release of this chart).
- Upstream **major** bumps (dashboard v2→v3, netbird 0.x→1.0) bump the chart
  major. Hand-made chart changes outside Renovate bump the chart patch.
- The HelmRelease sets `releaseName: netbird` and `targetNamespace: netbird`
  explicitly, so the PVC adoption annotations are `netbird` / `netbird` (the
  default name would be `netbird-netbird`). `resource-policy: keep` protects
  the PVC if helm-controller remediates a failed install by uninstalling.
- The test-cluster rehearsal uses plain `helm upgrade --install` with the same
  release name. Flux on k3d is out of scope; helm-controller-specific
  behaviour is covered by the explicit release name and the keep policy.

## Left to the builder

- Chart layout, value names, helpers.
- Renovate config details (`bumpVersion` per `matchUpdateTypes`, grouping).
  Verify how Renovate classifies `0.80.0 → 0.81.0` (it must count as minor).
- CI implementation (GitHub Actions, `helm push`, GHCR auth via
  `GITHUB_TOKEN`).
- The `netbird-rack` dependsOn fix.
