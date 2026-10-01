# rancher-vexscan-extension

A Rancher Manager UI extension for [vexscan](https://github.com/cwayne18/vexscan):
in-cluster, VEX-backed CVE presence/reachability triage, scoped to the exact
RKE2 build running on each downstream cluster.

It's the same idea as `vexscan --from-images <(kubectl get pods ...)` or
`contrib/vexscan-dashboard.py` in the main vexscan repo, but instead of a
one-off local command and a static HTML file you email around, the scan runs
on a schedule inside the cluster and the results show up natively in Rancher
- in the left nav, next to Fleet, Apps, Cluster Explorer, etc.

> **Status:** design scaffold / mockup. The extension package builds and
> installs (see below), but the backend chart and scanner image have not been
> published yet - this repo documents and scaffolds the full architecture so
> it can be built out incrementally.

## Why "exact RKE2 version", specifically

Every RKE2 GitHub release publishes an exact image manifest as a release
asset, e.g. for `v1.30.4+rke2r1`:

```
https://github.com/rancher/rke2/releases/download/v1.30.4%2Brke2r1/rke2-images-all.linux-amd64.txt
```

A node's kubelet version *is* that release tag - `kubectl get nodes -o
jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'` on an RKE2 node
literally returns `v1.30.4+rke2r1`. So the scanner never has to guess a
version or scan "whatever's running" heuristically: it reads the kubelet
version, downloads that exact release's manifest, and hands it straight to
`vexscan --images-from <manifest> --all --triage --format json`. Upgrade the
cluster, and the next scheduled scan automatically re-targets the new exact
build.

## Architecture

```mermaid
flowchart LR
    subgraph Downstream Cluster
        CJ[CronJob: vexscan-scanner] -->|kubectl get nodes| KV[kubelet version]
        KV -->|resolves exact tag| GH[rke2 GitHub release asset:\nrke2-images-all.linux-ARCH.txt]
        GH --> SCAN[vexscan --images-from ... --all --triage]
        SCAN -->|summary| CR[(VexScanReport CR)]
        SCAN -->|full JSON| CM[(ConfigMap)]
    end
    subgraph Rancher Manager UI
        PROD[vexscan product\npkg/vexscan] -->|Steve API| CR
        PROD -->|Scan Now = CronJob.runNow| CJ
    end
```

Two halves, each in this repo:

1. **`pkg/vexscan/`** - the actual Rancher Dashboard UI extension (Vue 3 +
   `@rancher/shell`), scaffolded with the official `@rancher/extension`
   generator. Adds a cluster-scoped "VEX Scan" product with:
   - an **Overview** page: RKE2 version, last scan time, severity summary
     cards, per-image findings table, and a **Scan Now** button.
   - a generic CRD list/detail view for `VexScanReport` objects (reusing
     Rancher's built-in generic resource pages - no bespoke list/detail
     plumbing needed for that part).
   - the nav entry only appears in clusters where the `vexscan.cattle.io`
     CRD group is actually installed (`ifHaveGroup`, the same pattern
     `rancher-gatekeeper` uses), so it doesn't show up on clusters that
     haven't installed the chart below.

2. **`charts/vexscan-scanner/`** + **`scanner/`** - the in-cluster backend.
   A small Helm chart (installable standalone, via Rancher Apps, or via
   Fleet) that creates:
   - the `VexScanReport` CRD (`vexscanreports.vexscan.cattle.io`)
   - RBAC (`ServiceAccount` + `ClusterRole`/`ClusterRoleBinding` for reading
     node versions and the CRD; a namespaced `Role`/`RoleBinding` for writing
     the results `ConfigMap`) for the **scanner itself**
   - two Rancher `RoleTemplate`s (`vexscan-view`/`vexscan-operate`) for
     **end users** - see "End-user RBAC" below
   - a `CronJob` (default: daily) running `scanner/entrypoint.sh` in a small
     image built on top of the real `ghcr.io/cwayne18/vexscan` image

### "Scan Now" doesn't need a custom backend action

The UI's "Scan Now" button does **not** call any bespoke server-side API.
Rancher Dashboard already ships a working `runNow()` action on `batch.cronjob`
resources (`shell/models/batch.cronjob.js`): it clones the CronJob's
`spec.jobTemplate` into a new one-shot `Job`, owned by the CronJob, and saves
it - exactly what you get from Workloads > CronJobs > (kebab) > **Run Now** in
stock Rancher. `pages/overview.vue` just fetches the `vexscan-scanner`
CronJob this chart created and calls `cronJob.runNow()`. No custom Steve
action or new backend endpoint - but the calling user still needs real
Kubernetes RBAC to create a `Job`/patch the `CronJob`, same as clicking
Run Now anywhere else in Rancher. See "End-user RBAC" below for how that's
granted.

### End-user RBAC

Rancher's own default per-cluster roles (`cluster-owner`/`cluster-member`/
read-only) don't automatically cover a custom CRD or a chart's own system
namespace, so without anything extra, only `cluster-owner` (full cluster
admin) could see a `VexScanReport` or click Scan Now. The chart installs two
`management.cattle.io/v3` `RoleTemplate`s instead, so a cluster-owner can
delegate narrower access from **Cluster > Users & Permissions**, the same
place they'd assign any other Rancher role:

| RoleTemplate       | Grants                                                                 |
| ------------------ | ----------------------------------------------------------------------|
| `vexscan-view`     | Read `VexScanReport` status (triage bucket/severity counts, phase) and the full `report.json.gz` ConfigMaps. No scan trigger. |
| `vexscan-operate`  | Everything in `vexscan-view`, plus create the `Job`/patch the `CronJob` needed for "Scan Now" (composed via `roleTemplateNames: [vexscan-view]`, not duplicated). |

`pages/overview.vue` checks `cluster/canCreate`/`cluster/canUpdate` on the
Job/CronJob types and disables "Scan Now" with an explanatory tooltip/banner
for `vexscan-view`-only users, instead of letting them click into a 403.

**Known limitation**: a `context: "cluster"` RoleTemplate compiles down to a
`ClusterRoleBinding`, so (consistent with how Rancher's own built-in cluster
roles work) the ConfigMap/Job/CronJob rules above are granted cluster-wide,
not scoped to just the `cattle-vexscan-system` namespace the chart installs
into. An admin wanting tighter per-namespace isolation should put that
namespace in its own Rancher Project and use a `context: "project"` variant
instead. Not yet validated against a live Rancher Prime cluster - see
"Validation status".

### Rancher Prime gating

vexscan is intended to be Prime-exclusive. Enforcement is layered, from
cosmetic to real:

1. **UI soft gate (implemented)** - `pages/overview.vue` calls the real
   `isRancherPrime()` helper from `@shell/config/version` (populated from
   the server's own `/rancherversion` API response) and shows a blocking
   banner/disables Scan Now when the connected server isn't Prime. This is
   a courtesy for anyone who installs the chart against a Community server;
   it does **not** stop them, since it's just JS shipped to the browser.
2. **Backend gate (not implemented)** - `scanner/entrypoint.sh` could make
   the same check server-side and fail the Job/CronJob outright. Harder to
   bypass than (1), but still just removable source.
3. **Distribution gate (not implemented, the one that actually matters)** -
   don't publish the chart/scanner image to a public registry or catalog at
   all; host both in a SUSE/Rancher support-entitlement-gated registry, the
   same pattern Rancher Prime's own hardened images already use. Access
   itself requires an active subscription, regardless of what the shipped
   code does or doesn't check.
4. **Bundle into Prime itself (not implemented)** - ship vexscan as a
   pre-registered extension inside the Rancher Prime server chart/image
   directly, so a Community Rancher install never has it to install in the
   first place. Closest to "bundled into Rancher Manager" as originally
   envisioned.

(1) is implemented in this repo. (2)-(4) are distribution/packaging
decisions outside a single extension repo's code and aren't done here.

### Why a CRD status summary + separate ConfigMap, not one big object

`VexScanReport.status` only holds summary severity/bucket counts and a small
`componentResults[]` list (one row per scanned image: name, finding count, and
a pointer to a ConfigMap). The full `vexscan --format json` output is written
to that ConfigMap instead of inline in the CR, so a big cluster doesn't risk
tripping etcd's per-object size limit. This mirrors the summary/detail split
used by tools like the Trivy Operator.

Validated against a real scan: 3 RKE2 component images alone produced a
3.4MB raw JSON report, far past the 1MiB hard limit the apiserver enforces on
ConfigMaps/Secrets. Seeing exactly what was ruled out, and why, is core to
what vexscan's triage is for, so `entrypoint.sh` never drops a whole status
bucket to save space. Instead it degrades in stages, gzipped throughout
(JSON compresses very well here - about 27x on real data):

1. the full report, as-is.
2. the full report with only the bulky per-finding `evidence` chains
   stripped (confirmed: ~190/2372 findings carried one on real data,
   accounting for over half the raw bytes - every finding and bucket is
   still present, just without the deepest forensic detail).
3. (last resort) capped to the top N findings per *status bucket*
   (affected/vexed/ruledOut/undetermined), ranked by severity within each
   bucket, so every bucket keeps representation instead of any one being
   zeroed out.

`status.summary`'s counts are never truncated at any stage, and any
degradation is recorded in `status.message`.


## Repo layout

```
pkg/vexscan/              Rancher Dashboard extension package
  product.ts               nav entry, CRD list columns, ifHaveGroup gating
  routing/                 Overview page route + reused generic CRD routes
  pages/overview.vue        dashboard: version, severities, table, Scan Now
  detail/...scanreport.vue  per-report detail view
  models/...scanreport.ts   typed getters over the CR's spec/status
  l10n/en-us.yaml           UI copy
  config/constants.ts       product/type name constants shared across files

charts/vexscan-scanner/   Helm chart for the in-cluster backend
  crds/                     VexScanReport CRD
  templates/                namespace, RBAC, CronJob

scanner/                  Scanner container
  entrypoint.sh             version resolution -> manifest download -> scan -> CR/ConfigMap write
  Dockerfile                built FROM ghcr.io/cwayne18/vexscan

mockup/                   Static, self-contained HTML mockup of the Overview
                          page (no Rancher/K8s needed to view it)
```

## Trying the extension UI

Requires Node v24+ and Yarn (the official extension tooling's requirement).

```sh
yarn install
yarn dev    # runs the dev-app shell at http://localhost:8005, pointed at a real Rancher API
```

Or build the package to load into an existing Rancher via Developer Load /
the Extensions catalog:

```sh
yarn build-pkg vexscan
```

## Trying the mockup

`mockup/dashboard.html` is a static, self-contained preview of the Overview
page's look - open it directly in a browser, no build step or cluster
required.

## Validation status

This repo is a scaffold/mockup, not yet run end-to-end against a real
cluster. What's been validated for real vs. what still needs one:

**Validated against real data** (built the actual `vexscan` binary and
`skopeo` from source, ran `vexscan --images-from` against a real `rke2`
GitHub release manifest):
- The RKE2 release manifest URL/encoding and manifest format.
- `vexscan` requires `skopeo` on `PATH` and a `/etc/containers/policy.json`
  trust policy to pull images - both were missing from the original
  `scanner/Dockerfile` and are now fixed.
- The real batch JSON schema (`schema_version`/`mode`/`targets`/`results[]`,
  uppercase `severity`, finding `status` vocabulary, `vex` sub-object shape).
- `entrypoint.sh`'s `jq` summary/bucket logic, run against real report JSON -
  counts reconcile exactly against the raw finding counts.
- The raw-report-vs-ConfigMap-size-limit problem described above, and the
  staged gzip/strip/cap fix, measured against real output (including
  confirming every status bucket keeps representation even under an
  artificially tiny size limit).

**Still needs a real cluster** (no docker/kind/kubectl available in the
sandbox this was built in): CRD admission/schema validation, `--subresource
status` patch semantics, RBAC enforcement for the scanner's ServiceAccount
vs. end users, CronJob/Job scheduling and `runNow()` behavior, and the UI's
`headers()`/Steve API field shapes (never run via `yarn dev` against a live
Rancher). If you have access to a kind/k3d cluster or a real RKE2 node, the
fastest path to closing that gap is `helm install` this chart and watching
the first `Job` it creates.

## Relationship to the vexscan CLI and contrib/ scripts

| | `vexscan` CLI | `contrib/vexscan-dashboard.py` | this extension |
|---|---|---|---|
| Runs | wherever you invoke it | local, one-off | scheduled, in-cluster |
| Image list | you provide it | you provide it | resolved from the running RKE2 version automatically |
| Output | stdout / file | one static HTML file | live CR + ConfigMap, browsable in Rancher |
| Re-scan | re-run manually | re-run manually | scheduled, or one click ("Scan Now") |
