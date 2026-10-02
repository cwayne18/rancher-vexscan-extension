# Minimal scanner image: vexscan CLI + kubectl + jq + curl, wrapping
# entrypoint.sh. Built from the same vexscan binary published by
# https://github.com/cwayne18/vexscan.
ARG VEXSCAN_VERSION=latest
FROM ghcr.io/cwayne18/vexscan:${VEXSCAN_VERSION} AS vexscan

FROM alpine:3.20
# vexscan's image mode shells out to skopeo to pull/inspect images without a
# local daemon - confirmed required by running vexscan --images-from against
# a real RKE2 manifest (it fails immediately without this).
RUN apk add --no-cache bash curl jq skopeo ca-certificates \
  && curl -fsSL -o /usr/local/bin/kubectl \
       "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/kubectl" \
  && chmod +x /usr/local/bin/kubectl

# skopeo refuses to run without a trust policy (confirmed by running it for
# real: "Error loading trust policy: config file not found"). Baking this into
# /etc/containers (rather than $HOME) keeps it readable under
# readOnlyRootFilesystem regardless of which user/HOME the container runs as.
# insecureAcceptAnything matches vexscan's own default - it only reads image
# content/metadata, it never runs anything from the image.
RUN mkdir -p /etc/containers \
  && printf '{"default":[{"type":"insecureAcceptAnything"}]}' > /etc/containers/policy.json

COPY --from=vexscan /usr/local/bin/vexscan /usr/local/bin/vexscan
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Numeric UID, not just a named user: Kubernetes' runAsNonRoot check can't
# resolve a named user from the image's /etc/passwd, so a USER directive
# with just a name fails pods with "image has non-numeric user (vexscan),
# cannot verify user is non-root" even though the user genuinely isn't root
# (confirmed live against a real cluster).
RUN addgroup -S -g 1000 vexscan && adduser -S -G vexscan -u 1000 vexscan
USER 1000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
