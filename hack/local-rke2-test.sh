#!/usr/bin/env bash
# Spins up a single-node RKE2 cluster in a Multipass VM, builds the
# vexscan-scanner image locally (no registry/GHCR dependency), loads it
# into the VM's containerd, and installs the vexscan-scanner Helm chart.
#
# Run this on your own machine (needs Docker, Multipass, Helm, kubectl, go
# on PATH) - it cannot run inside a sandboxed agent session.
#
# Usage:
#   ./hack/local-rke2-test.sh
#
# Env overrides:
#   VM_NAME      Multipass VM name (default: vexscan-rke2)
#   VM_CPUS      Multipass VM CPU count (default: 4)
#   VM_MEMORY    Multipass VM memory (default: 8G - RKE2's own docs list 4G
#                as bare minimum; 8G leaves headroom for the image import +
#                scan Job on top of the control plane, and was the likely
#                cause of a "ctr: EOF" failure under 4G)
#   VEXSCAN_DIR  path to a local checkout of cwayne18/vexscan
#                (default: ../vexscan, cloned if missing)
#   FRESH_VM     set to 1 to delete and recreate the VM first - use this if
#                a previous run left RKE2 in a half-started state (stale
#                etcd data / orphaned containerd-shim processes are the
#                most common cause of a confusing second-run failure)
set -euo pipefail

VM_NAME="${VM_NAME:-vexscan-rke2}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-8G}"
VEXSCAN_DIR="${VEXSCAN_DIR:-../vexscan}"
NAMESPACE="cattle-vexscan-system"
SCANNER_IMAGE="localhost/vexscan-scanner:dev"
FRESH_VM="${FRESH_VM:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
for t in multipass docker helm kubectl go git; do need "$t"; done

if [[ "$FRESH_VM" == "1" ]]; then
  echo "==> FRESH_VM=1: deleting any existing $VM_NAME first"
  multipass delete "$VM_NAME" --purge 2>/dev/null || true
fi

echo "==> 1/7 launching RKE2 VM ($VM_NAME: $VM_CPUS cpus, $VM_MEMORY mem)"
if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
  multipass launch --name "$VM_NAME" --cpus "$VM_CPUS" --memory "$VM_MEMORY" --disk 20G 22.04
fi
# `systemctl enable --now`'s own exit code is not treated as fatal here: on a
# VM reused from a previous run, startup can legitimately take a while to
# reconcile existing etcd state and still succeed - step 2 below is the
# actual source of truth for readiness, polling via kubectl rather than
# trusting systemd's synchronous start result.
multipass exec "$VM_NAME" -- bash -c '
  if ! systemctl is-active --quiet rke2-server 2>/dev/null; then
    curl -sfL https://get.rke2.io | sudo sh -
    sudo systemctl enable --now rke2-server || echo "systemctl start reported failure - checking actual readiness next" >&2
  fi
'

echo "==> 2/7 waiting for the node to report Ready (can take several minutes on first boot)"
multipass exec "$VM_NAME" -- bash -c '
  KCTL="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml"
  # NOTE: sudo does not inherit KUBECONFIG/PATH from this shell, so the
  # kubeconfig and binary path must be passed explicitly on every invocation.
  for i in $(seq 1 180); do
    $KCTL get nodes 2>/dev/null | grep -q " Ready" && exit 0
    if (( i % 6 == 0 )); then
      echo "    still waiting ($((i * 5))s elapsed)..." >&2
      $KCTL get nodes 2>&1 | sed "s/^/    /" >&2 || true
    fi
    sleep 5
  done
  echo "node never became Ready - last node state and rke2-server logs:" >&2
  $KCTL get nodes -o wide 2>&1 | sed "s/^/    /" >&2 || true
  sudo journalctl -u rke2-server --no-pager -n 80 2>&1 | sed "s/^/    /" >&2 || true
  exit 1
'

echo "==> 3/7 fetching kubeconfig"
VM_IP="$(multipass info "$VM_NAME" --format csv | tail -1 | cut -d, -f3)"
multipass exec "$VM_NAME" -- sudo cat /etc/rancher/rke2/rke2.yaml \
  | sed "s/127.0.0.1/$VM_IP/" > "$REPO_ROOT/rke2.yaml"
export KUBECONFIG="$REPO_ROOT/rke2.yaml"
kubectl get nodes -o wide
echo "    kubeconfig written to $REPO_ROOT/rke2.yaml (gitignored)"

echo "==> 4/7 building vexscan binary locally"
if [[ ! -d "$VEXSCAN_DIR" ]]; then
  git clone https://github.com/cwayne18/vexscan "$VEXSCAN_DIR"
fi
# GOOS=linux always: this binary gets COPY'd straight into the (Linux)
# scanner image below, not run on this Mac - without it, go build produces
# a macOS binary and the container fails with "cannot execute binary file:
# Exec format error" (confirmed live). GOARCH matches this host's arch,
# since Docker Desktop builds images natively for the host CPU arch.
(cd "$VEXSCAN_DIR" && GOOS=linux GOARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" go build -o vexscan .)

echo "==> 5/7 building scanner image (bypasses ghcr.io/cwayne18/vexscan base image -"
echo "       uses the binary just built above instead, so this works even before"
echo "       that image is published)"
cp "$VEXSCAN_DIR/vexscan" "$REPO_ROOT/scanner/vexscan.local"
trap 'rm -f "$REPO_ROOT/scanner/vexscan.local"' EXIT
docker build -t "$SCANNER_IMAGE" -f - "$REPO_ROOT/scanner" <<'DOCKERFILE'
FROM alpine:3.20
RUN apk add --no-cache bash curl jq skopeo ca-certificates \
  && curl -fsSL -o /usr/local/bin/kubectl \
       "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/kubectl" \
  && chmod +x /usr/local/bin/kubectl
RUN mkdir -p /etc/containers \
  && printf '{"default":[{"type":"insecureAcceptAnything"}]}' > /etc/containers/policy.json
COPY vexscan.local /usr/local/bin/vexscan
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/vexscan /usr/local/bin/entrypoint.sh
RUN addgroup -S -g 1000 vexscan && adduser -S -G vexscan -u 1000 vexscan
USER 1000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
DOCKERFILE

echo "==> 6/7 loading image into the VM's containerd"
docker save "$SCANNER_IMAGE" -o /tmp/vexscan-scanner.tar
multipass transfer /tmp/vexscan-scanner.tar "$VM_NAME":/tmp/vexscan-scanner.tar
multipass exec "$VM_NAME" -- bash -c 'echo "    VM disk/memory headroom before import:"; df -h / | sed "s/^/    /"; free -h | sed "s/^/    /"'
IMPORT_OK=0
for attempt in 1 2 3; do
  if multipass exec "$VM_NAME" -- sudo /var/lib/rancher/rke2/bin/ctr \
      --address /run/k3s/containerd/containerd.sock \
      -n k8s.io images import /tmp/vexscan-scanner.tar; then
    IMPORT_OK=1
    break
  fi
  echo "    import attempt $attempt failed, retrying..." >&2
  sleep 5
done
if [[ "$IMPORT_OK" != "1" ]]; then
  echo "image import failed after 3 attempts - checking for OOM kills:" >&2
  multipass exec "$VM_NAME" -- sudo dmesg 2>/dev/null | grep -i "killed process\|out of memory" | tail -20 | sed "s/^/    /" >&2 || true
  exit 1
fi
rm -f /tmp/vexscan-scanner.tar

echo "==> 7/7 installing vexscan-scanner and running a manual scan"
helm upgrade --install vexscan-scanner "$REPO_ROOT/charts/vexscan-scanner" \
  --namespace "$NAMESPACE" --create-namespace \
  --set image.repository=localhost/vexscan-scanner \
  --set image.tag=dev \
  --set image.pullPolicy=Never

kubectl -n "$NAMESPACE" delete job vexscan-manual-test --ignore-not-found
kubectl -n "$NAMESPACE" create job vexscan-manual-test --from=cronjob/vexscan-scanner
if ! kubectl -n "$NAMESPACE" wait --for=condition=complete job/vexscan-manual-test --timeout=300s; then
  echo "scan job didn't complete - pod status:" >&2
  kubectl -n "$NAMESPACE" get pods -l job-name=vexscan-manual-test >&2
  echo "pod describe (check Events/Reason for the real cause):" >&2
  kubectl -n "$NAMESPACE" describe pods -l job-name=vexscan-manual-test >&2
  kubectl -n "$NAMESPACE" logs job/vexscan-manual-test || true
  exit 1
fi
kubectl -n "$NAMESPACE" get vexscanreport cluster-scan -o yaml

cat <<EOF

Done. To point the Rancher-in-Docker server at this cluster too:
  1. In Rancher: Clusters > Import Existing > generate the registration command
  2. multipass exec $VM_NAME -- sudo <paste the kubectl apply command>

To re-run just the scan later:
  export KUBECONFIG=$REPO_ROOT/rke2.yaml
  kubectl -n $NAMESPACE delete job vexscan-manual-test --ignore-not-found
  kubectl -n $NAMESPACE create job vexscan-manual-test --from=cronjob/vexscan-scanner

To tear down:
  multipass delete $VM_NAME --purge
EOF
