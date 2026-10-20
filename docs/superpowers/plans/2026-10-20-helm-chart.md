# NetBird Helm Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `deploy/` kustomize base with a semver'd Helm chart published to `oci://ghcr.io/sifungurux/charts/netbird`, bumped by Renovate, and move the rack to a Flux `HelmRelease` without losing the database.

**Architecture:** One chart at `chart/netbird/`, a 1:1 port of `deploy/*.yaml` with the four `${VARS}` and the two homelab patches turned into values. A GitHub Actions workflow lints PRs, refuses chart changes without a version bump, and pushes new versions to GHCR on merge. The hosted Renovate app bumps image tags plus `Chart.yaml` version here, and the HelmRelease version in homelab.

**Tech Stack:** Helm 4 (local `v4.2.0`), yq v4, GitHub Actions, Renovate (hosted app), Flux `OCIRepository` + `HelmRelease`, k3d test cluster.

**Spec:** `docs/superpowers/specs/2026-10-20-helm-chart-design.md`

## Global Constraints

- Chart name `netbird`, path `chart/netbird/`, first `version: 1.0.0`.
- Publish target `oci://ghcr.io/sifungurux/charts` (package `charts/netbird`), **public**.
- Bump rule: upstream major → chart major, minor → minor, patch → patch; hand-made chart changes → patch.
- Images and defaults: `netbirdio/netbird-server:0.80.0`, `netbirdio/netbird:0.80.0` (same version, one Renovate group), `netbirdio/dashboard:v2.94.0` (own group).
- Release name `netbird`, namespace `netbird`. The chart never creates the Namespace and never creates Secrets.
- Resource names unchanged: `netbird-server`, `netbird-server-grpc`, `netbird-data`, `netbird-stun`, `netbird-dashboard`, `netbird-routing-peer`, `netbird` (EnvoyProxy/Gateway/HTTPRoute), `netbird-tls`, `netbird-streams`.
- PVC `netbird-data` carries `helm.sh/resource-policy: keep`.
- `domain`, `clusterIssuer`, `clusterName` are `required`; `gatewayClass` defaults to `envoy`.
- Every comment in `deploy/*.yaml` moves into the matching template.
- Always pass `--kube-context` / `--context` explicitly (`k3d-netbird-test` or `rack`).
- Commits: no `Co-Authored-By` trailer (user's global rule).

## Review Focus

1. **Render drift from `deploy/`**: the chart must render the same objects/specs as `make render` today, apart from Helm's labels. Pinned by `test/render-diff.sh` in Task 1.
2. **Missing required value renders an empty hostname**: expect a render failure. Pinned in Task 1 Step 5.
3. **Helm adopting the old PVC fails or creates a new one**: expect the same PV bound and the owner account still present. Pinned by the rehearsal in Task 3.
4. **A chart change merged without a version bump** silently never publishes. Pinned by `scripts/chart-version-check.sh` test in Task 2.
5. **Re-run of the publish job on an existing version** must not overwrite or fail. Pinned in Task 2 Step 6.

---

### Task 1: Chart, ported from `deploy/`

**Files:**
- Create: `chart/netbird/Chart.yaml`, `chart/netbird/values.yaml`, `chart/netbird/templates/{server,stun-service,dashboard,gateway,routing-peer}.yaml`, `test/values.yaml`, `test/render-diff.sh`
- Modify: `Makefile`, `test/verify.sh`
- Delete: `test/render.sh`, `test/vars.env` (after Step 7)

**Interfaces:**
- Produces values (exact keys, later tasks and homelab use them):
  ```yaml
  domain: ""            # required
  clusterIssuer: ""     # required
  gatewayClass: envoy
  clusterName: ""       # required
  gateway:
    serviceAnnotations: {}   # -> EnvoyProxy envoyService.annotations
  stun:
    serviceAnnotations: {}   # -> netbird-stun metadata.annotations
  server:
    image: {repository: netbirdio/netbird-server, tag: "0.80.0"}
    persistence: {size: 1Gi}
  dashboard:
    image: {repository: netbirdio/dashboard, tag: v2.94.0}
  routingPeer:
    image: {repository: netbirdio/netbird, tag: "0.80.0"}
  ```
  The `image: {repository, tag}` shape is what Renovate's `helm-values` manager detects; keep it.
- Produces `test/values.yaml` with `domain: netbird-test.nordkeel.dk`, `clusterIssuer: letsencrypt-prod`, `clusterName: test`.
- Produces Make targets: `make render` = `helm template netbird chart/netbird -n netbird -f test/values.yaml`; `make apply` = `helm upgrade --install netbird chart/netbird -n netbird -f test/values.yaml --kube-context k3d-netbird-test`.

- [ ] **Step 1: Write `test/render-diff.sh`** (temporary; deleted in Task 4 with `deploy/`). It renders both sides, drops `metadata.labels` keys `helm.sh/chart`, `app.kubernetes.io/managed-by`, `app.kubernetes.io/instance`, `app.kubernetes.io/version` (only if the chart adds them) and the Namespace object from the kustomize side, sorts docs by `kind/name` with `yq ea '[.] | sort_by(.kind, .metadata.name) | .[] | splitDoc'`, and `diff -u`s them. Exit 0 = identical.
  - Old side: `set -a; . test/vars.env; set +a; kubectl kustomize deploy | flux envsubst --strict`
  - New side: `helm template netbird chart/netbird -n netbird -f test/values.yaml`
  - Expected diff, besides nothing: the PVC gains `helm.sh/resource-policy: keep`. Whitelist exactly that annotation in the script.

- [ ] **Step 2: Run it to see it fail.** `test/render-diff.sh` → FAIL (`chart/netbird` not found).

- [ ] **Step 3: Write the chart.** One template per `deploy/` file (no `namespace.yaml`), comments carried over, `metadata.namespace: {{ .Release.Namespace }}`. Values from the Interfaces block; `{{ required "domain is required" .Values.domain }}` etc. at first use. `serviceAnnotations` rendered with `toYaml`; the EnvoyProxy keeps `annotations: {}` when empty, `netbird-stun` omits `metadata.annotations` when empty. No `_helpers.tpl`, no extra labels (Review Focus 1). `Chart.yaml`: `apiVersion: v2`, `name: netbird`, `version: 1.0.0`, `description`, no `appVersion` (`# ponytail: images live in values.yaml, Renovate bumps them there; appVersion would be a second copy to keep in sync`).

- [ ] **Step 4: Run the diff to see it pass.** `test/render-diff.sh` → no output, exit 0. Also `helm lint chart/netbird -f test/values.yaml` → `0 chart(s) failed`.

- [ ] **Step 5: Required values fail the render.** Add to `test/render-diff.sh`, after the diff:
  ```bash
  for v in domain clusterIssuer clusterName; do
    if helm template netbird chart/netbird -f test/values.yaml --set "$v=" >/dev/null 2>&1; then
      echo "FAIL: render succeeded without $v" >&2; exit 1; fi
  done
  ```
  Run → exit 0. Then temporarily drop one `required` and confirm it exits 1; restore.

- [ ] **Step 6: Annotations land where homelab needs them.** Add to the script:
  ```bash
  out=$(helm template netbird chart/netbird -f test/values.yaml \
    --set-string 'gateway.serviceAnnotations.metallb\.io/loadBalancerIPs=192.168.150.40' \
    --set-string 'stun.serviceAnnotations.metallb\.io/loadBalancerIPs=192.168.150.41')
  [[ $(yq 'select(.kind=="EnvoyProxy").spec.provider.kubernetes.envoyService.annotations."metallb.io/loadBalancerIPs"' <<<"$out") == 192.168.150.40 ]]
  [[ $(yq 'select(.kind=="Service" and .metadata.name=="netbird-stun").metadata.annotations."metallb.io/loadBalancerIPs"' <<<"$out") == 192.168.150.41 ]]
  ```
  Run → exit 0.

- [ ] **Step 7: Switch the test tooling.** Create `test/values.yaml`; Makefile targets as in Interfaces (`render` keeps `make render` usable without a cluster). `test/verify.sh`: replace `source vars.env` with `NETBIRD_DOMAIN=${NETBIRD_DOMAIN:-$(yq .domain values.yaml)}` (env override is how Task 5 verifies the rack). Keep `test/vars.env` and `test/render.sh` until Task 4 (render-diff needs `vars.env`).
  Run: `make render | yq 'select(.kind=="Gateway").spec.listeners[0].hostname'` → `netbird-test.nordkeel.dk`.

- [ ] **Step 8: Commit.** `git add chart test Makefile && git commit -m "Chart: port deploy/ to chart/netbird 1.0.0"`

---

### Task 2: CI — lint, version check, publish

**Files:**
- Create: `scripts/chart-version-check.sh`, `.github/workflows/chart.yaml`

**Interfaces:**
- `scripts/chart-version-check.sh <base-ref>`: exit 0 if nothing under `chart/` changed vs `<base-ref>`, or if `chart/netbird/Chart.yaml` `.version` differs from `<base-ref>`'s and is greater (`sort -V`). Exit 1 with `chart/ changed but version is still X` otherwise.

- [ ] **Step 1: Write the test** `scripts/chart-version-check.test.sh`: in a `mktemp -d` throwaway git repo with a copy of `chart/`, assert:
  - no change → exit 0
  - `values.yaml` edited, version same → exit 1
  - `values.yaml` edited, version `1.0.0`→`1.0.1` → exit 0
  - version lowered `1.0.0`→`0.9.0` → exit 1

- [ ] **Step 2: Run it → FAIL** (script missing).
- [ ] **Step 3: Implement** with `git diff --quiet <base-ref> -- chart/` and `git show <base-ref>:chart/netbird/Chart.yaml | yq .version`.
- [ ] **Step 4: Run it → PASS** (all four cases).

- [ ] **Step 5: Write `.github/workflows/chart.yaml`.**
  - `on: pull_request` (paths `chart/**`, `scripts/chart-version-check.sh`, `test/values.yaml`) and `push: branches: [main]` (paths `chart/**`).
  - Job `check` (PR): `actions/checkout` with `fetch-depth: 0`; `azure/setup-helm` (pin by SHA with version comment, as unpacker does); `helm lint chart/netbird -f test/values.yaml`; `helm template ... -f test/values.yaml > /dev/null`; `scripts/chart-version-check.sh origin/${{ github.base_ref }}`.
  - Job `publish` (push to main): `permissions: packages: write, contents: read`; `helm registry login ghcr.io -u ${{ github.actor }} --password-stdin <<< "$GITHUB_TOKEN"`; read version with `yq`; if `helm show chart oci://ghcr.io/sifungurux/charts/netbird --version "$v"` succeeds, print `already published` and exit 0; else `helm package chart/netbird` and `helm push netbird-$v.tgz oci://ghcr.io/sifungurux/charts`.
- [ ] **Step 6: Check the publish logic locally** without pushing: run the `helm show chart` guard against `--version 0.0.0-nonexistent` → non-zero (would publish); after the first real publish, against `1.0.0` → zero (skips). Lint the workflow with `actionlint` if installed (`brew install actionlint` is fine to suggest, not required).
- [ ] **Step 7: Commit.** `git add scripts .github && git commit -m "CI: lint chart, require version bump, publish to GHCR"`

---

### Task 3: Cutover rehearsal on the test cluster

No new files beyond the runbook section; this proves the PVC handover before the rack.

**Interfaces:**
- Consumes: `make apply` from Task 1.
- Produces: the exact command sequence for README "Cutover" (Task 4) and homelab (Task 5).

- [ ] **Step 1: Start from the old layout.** `make up`; on `main`'s `deploy/` (`git stash`/worktree): `test/render.sh | kubectl --context k3d-netbird-test apply --server-side -f -`. Secrets present (`scripts/secrets.sh` per README). Owner account exists, routing peer connected.
- [ ] **Step 2: Record the "before".** `kubectl --context k3d-netbird-test -n netbird get pvc netbird-data -o jsonpath='{.spec.volumeName}'` → note PV name. `curl -s https://netbird-test.nordkeel.dk/api/instance` → note body (expect `setup_required` false). If that endpoint 404s, note that the dashboard shows the login, not the owner-setup screen.
- [ ] **Step 3: Remove old objects except PVC, Namespace, Secrets.** `test/render.sh | yq 'select(.kind != "Namespace" and .kind != "PersistentVolumeClaim")' | kubectl --context k3d-netbird-test delete -f -` (stands in for Flux's prune).
- [ ] **Step 4: Hand the PVC to Helm.**
  ```bash
  kubectl --context k3d-netbird-test -n netbird label pvc netbird-data app.kubernetes.io/managed-by=Helm --overwrite
  kubectl --context k3d-netbird-test -n netbird annotate pvc netbird-data meta.helm.sh/release-name=netbird meta.helm.sh/release-namespace=netbird --overwrite
  ```
- [ ] **Step 5: Install the chart.** On this branch: `make apply`. Expected: `STATUS: deployed`, no "exists and cannot be imported" error.
- [ ] **Step 6: Verify "after".** Same PV name as Step 2; `/api/instance` body identical (or dashboard login, not setup); `make verify` → `ALL OK`; routing peer pod Running and a new peer visible in the dashboard (ephemeral key, expected).
- [ ] **Step 7: Uninstall keeps the PVC.** `helm --kube-context k3d-netbird-test -n netbird uninstall netbird` → output lists `netbird-data` as kept; `kubectl ... get pvc netbird-data` still Bound. Reinstall with `make apply`, re-run Step 6 checks.
- [ ] **Step 8: Log it** in `docs/test-log.md` (date, steps, results) and commit: `git commit -am "Test log: chart cutover rehearsal on k3d"`.

---

### Task 4: Docs, Renovate, remove `deploy/`

**Files:**
- Create: `renovate.json`
- Modify: `README.md`, `CLAUDE.md`, `docs/superpowers/specs/2026-10-10-netbird-homelab-design.md` (Packaging row → "superseded by 2026-10-20-helm-chart-design.md")
- Delete: `deploy/`, `test/render.sh`, `test/vars.env`, `test/render-diff.sh`

- [ ] **Step 1: Write `renovate.json`:**
  ```json
  {
    "$schema": "https://docs.renovatebot.com/renovate-schema.json",
    "extends": ["config:recommended"],
    "enabledManagers": ["helm-values", "github-actions"],
    "packageRules": [
      {"matchManagers": ["helm-values"], "matchPackageNames": ["netbirdio/netbird-server", "netbirdio/netbird"], "groupName": "netbird"},
      {"matchManagers": ["helm-values"], "matchUpdateTypes": ["major"], "bumpVersion": "major"},
      {"matchManagers": ["helm-values"], "matchUpdateTypes": ["minor"], "bumpVersion": "minor"},
      {"matchManagers": ["helm-values"], "matchUpdateTypes": ["patch"], "bumpVersion": "patch"}
    ]
  }
  ```
  Validate: `npx --yes --package renovate -- renovate-config-validator renovate.json` → `Config validated successfully`.
  Note for the first real PR: confirm Renovate labels `0.80.0 → 0.81.0` as `minor` (0.x semver). If it says `major`, add `"matchCurrentVersion": "<1.0.0"` rules mapping major→minor for the netbird group and record it here.
- [ ] **Step 2: Delete** `deploy/`, `test/render.sh`, `test/vars.env`, `test/render-diff.sh`. `grep -rn 'deploy/\|vars.env\|render.sh\|envsubst' --exclude-dir=.git --exclude-dir=docs .` → no hits.
- [ ] **Step 3: Update `CLAUDE.md` Key facts** — replace the `deploy/`/four-variable bullet with: chart at `chart/netbird`, values (not `${VARS}`), every chart change bumps `version` (CI enforces), `make render` = `helm template`. Keep the context and secrets bullets.
- [ ] **Step 4: Update `README.md`** — Layout (chart/, no deploy/), values table (value names from Task 1 instead of variables), Test cluster commands, a "Releasing" section (Renovate PR → merge → CI publishes; manual changes bump patch), a "Cutover" section with Task 3's sequence. Gotchas unchanged.
- [ ] **Step 5: Final checks.** `make render >/dev/null && helm lint chart/netbird -f test/values.yaml`; `scripts/chart-version-check.test.sh`.
- [ ] **Step 6: Commit and PR.** `git commit -m "Remove deploy/, add Renovate, docs for the chart"`; PR to `main` (use the `pr-description` skill). After merge: confirm the `publish` job pushed `1.0.0`, then **once, by hand**: GitHub → Packages → `charts/netbird` → Package settings → Change visibility → Public. Check: `helm show chart oci://ghcr.io/sifungurux/charts/netbird --version 1.0.0` with no `helm registry login` → prints the chart. Install the Renovate GitHub app on `Sifungurux/k8s-netbird` (and homelab, for Task 5).

---

### Task 5: Rack cutover (Sifungurux/homelab) — done from home, on the LAN

**Files (homelab):**
- Create: `clusters/rack/netbird-namespace.yaml`, `renovate.json`
- Replace: `clusters/rack/sources/netbird.yaml` (GitRepository → OCIRepository), `clusters/rack/releases/netbird.yaml` (Kustomization → HelmRelease)
- Modify: `clusters/rack/kustomization.yaml`, `clusters/rack/releases/netbird-rack.yaml`

**Interfaces:**
- Consumes: chart `1.0.0` public on GHCR; values keys from Task 1; PVC handover from Task 3.

- [ ] **Step 1: Back up.** From the LAN: `kubectl --context rack -n netbird get secret netbird-server-config -o yaml` → LastPass note (already there per secrets.sh; confirm it matches). Copy the store: `kubectl --context rack -n netbird exec deploy/netbird-server -- tar -C /var/lib/netbird -cf - . > netbird-data-$(date +%F).tar`; check `tar -tf` lists the store DB. Record PV name and `/api/instance` body as in Task 3 Step 2.
- [ ] **Step 2: Commit A — remove the old, keep the Namespace.**
  - `clusters/rack/netbird-namespace.yaml`: the Namespace from `deploy/namespace.yaml`, comment included (prune disabled).
  - `kustomization.yaml`: add `netbird-namespace.yaml`; remove `sources/netbird.yaml`, `releases/netbird.yaml`.
  - Delete those two files, and the `k8s-netbird-git-auth` secret reference in the README (the secret itself: `kubectl --context rack -n flux-system delete secret k8s-netbird-git-auth` after Step 3).
  - `releases/netbird-rack.yaml`: drop `dependsOn` (it retries every 1m until CRDs and the namespace exist, which it already tolerates); update its comment.
  - Push; `flux --context rack reconcile ks flux-system --with-source`. Expected: `kubectl --context rack -n netbird get all` shows nothing; PVC and Secrets still there.
- [ ] **Step 3: Hand the PVC to Helm** — Task 3 Step 4 with `--context rack`, plus remove Flux's ownership labels: `kubectl --context rack -n netbird label pvc netbird-data kustomize.toolkit.fluxcd.io/name- kustomize.toolkit.fluxcd.io/namespace-`.
- [ ] **Step 4: Commit B — the HelmRelease.**
  - `sources/netbird.yaml`: `OCIRepository` `k8s-netbird` in `flux-system`, `url: oci://ghcr.io/sifungurux/charts/netbird`, `ref.tag: 1.0.0`, `layerSelector: {mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip, operation: copy}`, no `secretRef` (public).
  - `releases/netbird.yaml`: `HelmRelease` `netbird` in `flux-system`, `releaseName: netbird`, `targetNamespace: netbird`, `chartRef: {kind: OCIRepository, name: k8s-netbird}`, `dependsOn: [{name: cert-manager}]`, `install.timeout: 10m`, values: `domain: netbird.nordkeel.dk`, `clusterIssuer: letsencrypt-prod`, `clusterName: rack`, `gateway.serviceAnnotations: {metallb.io/loadBalancerIPs: 192.168.150.40}`, `stun.serviceAnnotations: {metallb.io/loadBalancerIPs: 192.168.150.41}`. Keep the old file's comment about the router forwards.
  - `kustomization.yaml`: add both back; update the NetBird comment (chart from GHCR, not k8s-netbird's deploy/).
  - `renovate.json`: `config:recommended`, `enabledManagers: ["flux"]`.
  - Push; reconcile. Expected: `flux --context rack get hr netbird` → `Ready True`, `Helm install succeeded`.
- [ ] **Step 5: Verify.** Same PV name; `/api/instance` unchanged; Envoy Service `EXTERNAL-IP 192.168.150.40`, `netbird-stun` `192.168.150.41`; `NETBIRD_DOMAIN=netbird.nordkeel.dk make verify` → `ALL OK`; phone on 4G reaches the LAN through the routing peer.
- [ ] **Step 6: Confirm Renovate sees it.** Renovate's onboarding/dependency dashboard in homelab lists `oci://ghcr.io/sifungurux/charts/netbird 1.0.0`. Log the cutover in k8s-netbird `docs/test-log.md`.

Rollback (if Step 4 fails before Step 5 passes): restore the PVC labels, revert commits A+B; the old commit-pinned Kustomization comes back against the same PVC and Secret.
