#!/usr/bin/env bash
# Entry point for the vexscan-scanner CronJob/Job.
#
# 1. Reads the exact RKE2 build this cluster's node(s) report (kubelet
#    version == RKE2's own release tag, e.g. v1.30.4+rke2r1).
# 2. Downloads that exact release's image manifest from the rke2 GitHub
#    release (rke2-images-all.linux-<arch>.txt), so the scan covers exactly
#    the images this RKE2 build actually ships - never a generic/latest list.
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
MANIFEST_URL="https://github.com/rancher/rke2/releases/download/${ENCODED_TAG}/rke2-images-all.linux-${RKE2_ARCH}.txt"

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
vexscan --images-from "$WORKDIR/images.txt" --all --triage --quiet \
  --format json --out "$WORKDIR/report.json"

echo "==> summarizing report"
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

COMPONENT_RESULTS_JSON="$(jq -c '
  [.results[] | {
    component: (.target // .module // "unknown"),
    image: .target,
    findings: (.findings | length),
    reportConfigMapRef: $cmName
  }]
' --arg cmName "${REPORT_NAME}-report" "$WORKDIR/report.json")"

echo "==> writing full report ConfigMap ${REPORT_NAME}-report"
kubectl create configmap "${REPORT_NAME}-report" -n "$REPORT_NAMESPACE" \
  --from-file=report.json="$WORKDIR/report.json" \
  --dry-run=client -o yaml | kubectl apply -f -

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATUS_PATCH="$(jq -n \
  --arg rke2Version "$KUBELET_VERSION" \
  --argjson summary "$SUMMARY_JSON" \
  --argjson componentResults "$COMPONENT_RESULTS_JSON" \
  --arg lastScanTime "$NOW" \
  '{status: {phase: "Ready", lastScanTime: $lastScanTime, summary: $summary, componentResults: $componentResults, message: ""}}')"

echo "==> patching VexScanReport/$REPORT_NAME status"
kubectl patch vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" --type=merge --subresource=status \
  -p "$STATUS_PATCH"

# Keep spec.rke2Version in sync too, in case this is the CR's first run
# (the chart only seeds metadata, not spec, on install).
kubectl patch vexscanreport "$REPORT_NAME" -n "$REPORT_NAMESPACE" --type=merge \
  -p "$(jq -n --arg v "$KUBELET_VERSION" --arg n "$(hostname)" '{spec: {rke2Version: $v, sourceNode: $n}}')"

echo "==> done"
