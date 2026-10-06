#!/usr/bin/env bash
# Entry point for the vexscan-scanner CronJob/Job.
#
# 1. Reads the exact RKE2 build this cluster's node(s) report (kubelet
#    version == RKE2's own release tag, e.g. v1.30.4+rke2r1).
# 2. Downloads that exact release's image manifest from the rke2 GitHub
#    release (rke2-images.linux-<arch>.txt - the default-install image set,
#    NOT rke2-images-all, which is the union of every optional CNI/cloud-
#    provider add-on across every possible config and would pull in images
#    this cluster never actually runs, e.g. vSphere/AWS/Azure CSI drivers),
#    so the scan covers exactly the images this RKE2 build actually ships -
#    never a generic/latest or kitchen-sink list.
# 3. Runs vexscan over that manifest and writes the full JSON to a
#    ConfigMap, then patches the VexScanReport CR's status with a small
#    summary (so the CR itself stays well under etcd's per-object limit).
set -euo pipefail

REPORT_NAME="${REPORT_NAME:-cluster-scan}"
REPORT_NAMESPACE="${REPORT_NAMESPACE:-cattle-vexscan-system}"
RKE2_IMAGE_PREFIX="${RKE2_IMAGE_PREFIX:-rancher/}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> resolving RKE2 version from node kubelet version"
KUBELET_VERSION="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"

if [[ ! "$KUBELET_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+rke2r[0-9]+$ ]]; then
  echo "node kubelet version '$KUBELET_VERSION' does not look like an RKE2 build (expected vX.Y.Z+rke2rN)" >&2
  kubectl patch vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" --type=merge \
    --subresource=status -p "{\"status\":{\"phase\":\"Failed\",\"message\":\"not an RKE2 cluster: kubelet version $KUBELET_VERSION\"}}" || true
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  RKE2_ARCH=amd64 ;;
  aarch64) RKE2_ARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# GitHub release asset URLs url-encode "+" as %2B in the release tag.
ENCODED_TAG="${KUBELET_VERSION//+/%2B}"
MANIFEST_URL="https://github.com/rancher/rke2/releases/download/${ENCODED_TAG}/rke2-images.linux-${RKE2_ARCH}.txt"

echo "==> RKE2 version: $KUBELET_VERSION ($RKE2_ARCH)"
echo "==> downloading image manifest: $MANIFEST_URL"
curl -fsSL -o "$WORKDIR/images.txt" "$MANIFEST_URL"

# The chart ships the CRD but not the CR itself - create it idempotently on
# first run so later `kubectl patch --subresource=status` calls have
# something to patch.
kubectl get vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" >/dev/null 2>&1 || \
  kubectl apply -f - <<EOF
apiVersion: vexscan.cattle.io/v1
kind: VexScanReport
metadata:
  name: $REPORT_NAME
  namespace: $REPORT_NAMESPACE
spec:
  rke2Version: "$KUBELET_VERSION"
EOF

kubectl patch vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" --type=merge --subresource=status \
  -p '{"status":{"phase":"Scanning"}}' || true

echo "==> running vexscan"
# vexscan exits non-zero whenever any ecosystem/image fails to complete,
# even without --fail-on (exit 1 means "the scan did not complete" by
# design - see vexscan's own failon.go). Under `set -e` that would
# otherwise kill this script right here, leaving the CR stuck at
# phase=Scanning forever with no record of what happened. Capture the
# failure instead, mark the CR Failed with vexscan's own stderr as the
# message, and exit - still non-zero, so the Job/CronJob correctly shows
# as failed too.
if ! vexscan --images-from "$WORKDIR/images.txt" --all --triage --quiet \
    --format json --out "$WORKDIR/report.json" 2>"$WORKDIR/vexscan.stderr"; then
  cat "$WORKDIR/vexscan.stderr" >&2
  VEXSCAN_ERR="$(tail -c 1000 "$WORKDIR/vexscan.stderr" | jq -Rs .)"
  kubectl patch vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" --type=merge \
    --subresource=status -p "{\"status\":{\"phase\":\"Failed\",\"message\":$VEXSCAN_ERR}}" || true
  exit 1
fi

echo "==> summarizing report"
# vexscan's `Findings []Finding` field has no `omitempty`, so Go serializes
# a zero-finding image's nil slice as JSON `null`, not `[]`. Every jq filter
# below assumes `.findings` is always an array (`.findings[]`), which
# throws "Cannot iterate over null (null)" the first time a scanned image
# has zero findings. Normalize once here instead of null-guarding every
# filter separately.
jq -c '.results[].findings |= (. // [])' "$WORKDIR/report.json" > "$WORKDIR/report.normalized.json"
mv "$WORKDIR/report.normalized.json" "$WORKDIR/report.json"

# Severity buckets: vexscan's own --severity values.
# Finding buckets mirror contrib/vexscan-dashboard.py's bucket_of(): a
# reachable/linked finding is "affected" unless an exculpatory VEX statement
# (not_affected/fixed) applies, in which case it is "vexed"; not_present and
# not_in_execute_path are "ruledOut"; anything else is "undetermined".
SUMMARY_JSON="$(jq -c '
  [.results[].findings[]] as $all
  | {
      critical:    ([$all[] | select((.severity // "") | ascii_upcase == "CRITICAL")] | length),
      high:        ([$all[] | select((.severity // "") | ascii_upcase == "HIGH")] | length),
      medium:      ([$all[] | select((.severity // "") | ascii_upcase == "MEDIUM")] | length),
      low:         ([$all[] | select((.severity // "") | ascii_upcase == "LOW")] | length),
      unknown:     ([$all[] | select(((.severity // "") | ascii_upcase) as $s | $s == "" or $s == "UNKNOWN" or $s == "NONE")] | length),
      affected:    ([$all[] | select(.status == "linked" or .status == "reachable")
                              | select(((.vex.status // "") as $vs | ($vs != "not_affected" and $vs != "fixed")))] | length),
      vexed:       ([$all[] | select(.status == "linked" or .status == "reachable")
                              | select((.vex.status // "") == "not_affected" or (.vex.status // "") == "fixed")] | length),
      ruledOut:    ([$all[] | select(.status == "not_present" or .status == "not_in_execute_path")] | length),
      undetermined: ([$all[] | select(.status != "linked" and .status != "reachable"
                               and .status != "not_present" and .status != "not_in_execute_path")] | length),
    }
' "$WORKDIR/report.json")"

# Per-component bucket counts, same bucket_of() rules as SUMMARY_JSON above.
# Computed from the full/original report.json (never from the possibly-
# truncated report.filtered.json), so these counts stay accurate even when
# the persisted ConfigMap below had to be degraded - mirrors
# status.summary's own never-truncated guarantee. "findings" is kept too
# (= affected+vexed+undetermined+ruledOut) for anything still reading the
# old flat field.
COMPONENT_RESULTS_JSON="$(jq -c '
  def bucket:
    if (.status=="linked" or .status=="reachable") then
      ((.vex.status // "") as $vs | if ($vs=="not_affected" or $vs=="fixed") then "vexed" else "affected" end)
    elif (.status=="not_present" or .status=="not_in_execute_path") then "ruledOut"
    else "undetermined" end;
  [.results[] | {
    component: (.target // .module // "unknown"),
    image: .target,
    findings: (.findings | length),
    affected: ([.findings[] | select(bucket == "affected")] | length),
    vexed: ([.findings[] | select(bucket == "vexed")] | length),
    undetermined: ([.findings[] | select(bucket == "undetermined")] | length),
    ruledOut: ([.findings[] | select(bucket == "ruledOut")] | length),
    reportConfigMapRef: $cmName
  }]
' --arg cmName "${REPORT_NAME}-report" "$WORKDIR/report.json")"

# ConfigMaps are hard-capped at 1MiB by the apiserver, and a real scan's raw
# JSON easily exceeds that (confirmed: 3 RKE2 images alone produced a 3.4MB
# report). Ruled-out findings are NOT dropped here - seeing exactly what was
# ruled out, and why, is a core part of what vexscan's triage is for, not
# noise to discard. Instead this degrades in stages, each one still gzipped
# (JSON compresses very well - confirmed ~27x on real data):
#   1. the full report, as-is.
#   2. the full report with only the bulky per-finding `evidence` chains
#      stripped (confirmed: ~190/2372 findings carried one of these on real
#      data, accounting for >50% of raw bytes; every finding/bucket is still
#      present, just without the deepest forensic detail).
#   3. (last resort) capped to the top N findings per *status bucket*
#      (affected/vexed/ruledOut/undetermined), ranked by severity within each
#      bucket, so every bucket keeps representation instead of any one being
#      zeroed out. status.summary's counts are never truncated at any stage.
CONFIGMAP_SIZE_LIMIT=900000 # stay under the 1MiB apiserver cap with margin
PER_BUCKET_FINDING_CAP="${PER_BUCKET_FINDING_CAP:-500}"
TRUNCATION_NOTE=""

gzip_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }

cp "$WORKDIR/report.json" "$WORKDIR/report.filtered.json"
gzip -c "$WORKDIR/report.filtered.json" > "$WORKDIR/report.json.gz"

if [[ "$(gzip_size "$WORKDIR/report.json.gz")" -gt "$CONFIGMAP_SIZE_LIMIT" ]]; then
  echo "==> full report exceeds ${CONFIGMAP_SIZE_LIMIT} bytes compressed, stripping per-finding evidence chains"
  jq -c 'del(.results[].findings[].evidence)' "$WORKDIR/report.json" > "$WORKDIR/report.filtered.json"
  gzip -c "$WORKDIR/report.filtered.json" > "$WORKDIR/report.json.gz"
  TRUNCATION_NOTE="verbose per-finding evidence chains were stripped from the persisted report to fit the ConfigMap size limit; every finding's status/justification is preserved, re-run vexscan directly for full evidence"
fi

if [[ "$(gzip_size "$WORKDIR/report.json.gz")" -gt "$CONFIGMAP_SIZE_LIMIT" ]]; then
  echo "==> still exceeds ${CONFIGMAP_SIZE_LIMIT} bytes compressed, capping to top ${PER_BUCKET_FINDING_CAP} findings per status bucket"
  jq -c --argjson cap "$PER_BUCKET_FINDING_CAP" '
    def bucket:
      if (.status=="linked" or .status=="reachable") then
        ((.vex.status // "") as $vs | if ($vs=="not_affected" or $vs=="fixed") then "vexed" else "affected" end)
      elif (.status=="not_present" or .status=="not_in_execute_path") then "ruledOut"
      else "undetermined" end;
    def sevRank:
      ((.severity // "") | ascii_upcase) as $s
      | if $s=="CRITICAL" then 5 elif $s=="HIGH" then 4 elif $s=="MEDIUM" then 3 elif $s=="LOW" then 2 else 1 end;
    ([.results[] as $r | $r.findings[] | {target: $r.target, mode: $r.mode, module: $r.module, finding: .}]) as $flat
    | ($flat | group_by(.finding | bucket) | map(sort_by(-(.finding | sevRank)) | .[0:$cap]) | add) as $kept
    | {
        schema_version, mode,
        results: ($kept | group_by(.target) | map({
          target: .[0].target, mode: .[0].mode, module: .[0].module,
          findings: map(.finding)
        }))
      }
  ' "$WORKDIR/report.filtered.json" > "$WORKDIR/report.filtered.json.tmp"
  mv "$WORKDIR/report.filtered.json.tmp" "$WORKDIR/report.filtered.json"
  gzip -c "$WORKDIR/report.filtered.json" > "$WORKDIR/report.json.gz"
  TRUNCATION_NOTE="persisted report was capped to the top ${PER_BUCKET_FINDING_CAP} findings per status bucket (affected/vexed/ruledOut/undetermined) due to ConfigMap size limits; every bucket is still represented and summary counts remain accurate for all findings"
fi

echo "==> writing report ConfigMap ${REPORT_NAME}-report ($(wc -c < "$WORKDIR/report.json.gz") bytes gzipped)"
kubectl create configmap "${REPORT_NAME}-report" -n "$REPORT_NAMESPACE" \
  --from-file=report.json.gz="$WORKDIR/report.json.gz" \
  --dry-run=client -o yaml | kubectl apply -f -

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Lightweight scan-history trend: summary counts only (no findings/evidence),
# appended to whatever history the CR already carries and capped to the last
# N entries here in the script - not left to the apiserver/CRD, since a JSON
# merge patch replaces the whole array anyway. This avoids a CR-per-scan +
# retention-job design entirely: one object, bounded size, no pruning CronJob
# to write/maintain.
HISTORY_LIMIT="${HISTORY_LIMIT:-30}"
PREV_HISTORY_JSON="$(kubectl get vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" \
  -o jsonpath='{.status.history}' 2>/dev/null || true)"
# kubectl's jsonpath output for a field that has never been set (true on a
# CR's first-ever successful scan) isn't reliably an empty string across
# kubectl versions - validate it's real, non-null JSON instead of guessing
# the exact placeholder text, and fall back to an empty history otherwise.
if ! jq -e . >/dev/null 2>&1 <<<"$PREV_HISTORY_JSON"; then
  PREV_HISTORY_JSON="[]"
fi

HISTORY_JSON="$(jq -c --argjson prev "$PREV_HISTORY_JSON" --argjson cap "$HISTORY_LIMIT" \
  --arg time "$NOW" --arg rke2Version "$KUBELET_VERSION" --argjson summary "$SUMMARY_JSON" '
  ($prev + [($summary + { time: $time, rke2Version: $rke2Version })]) as $all
  | $all[-$cap:]
')"

STATUS_PATCH="$(jq -n \
  --arg rke2Version "$KUBELET_VERSION" \
  --argjson summary "$SUMMARY_JSON" \
  --argjson componentResults "$COMPONENT_RESULTS_JSON" \
  --arg lastScanTime "$NOW" \
  --arg message "$TRUNCATION_NOTE" \
  --argjson history "$HISTORY_JSON" \
  '{status: {phase: "Ready", lastScanTime: $lastScanTime, summary: $summary, componentResults: $componentResults, message: $message, history: $history}}')"

echo "==> patching VexScanReport/$REPORT_NAME status"
kubectl patch vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" --type=merge --subresource=status \
  -p "$STATUS_PATCH"

# Keep spec.rke2Version in sync too, in case this is the CR's first run
# (the chart only seeds metadata, not spec, on install).
kubectl patch vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" --type=merge \
  -p "$(jq -n --arg v "$KUBELET_VERSION" --arg n "$(hostname)" '{spec: {rke2Version: $v, sourceNode: $n}}')"

echo "==> done"
