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

RUN addgroup -S vexscan && adduser -S -G vexscan vexscan
USER vexscan

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
