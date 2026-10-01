# Minimal scanner image: vexscan CLI + kubectl + jq + curl, wrapping
# entrypoint.sh. Built from the same vexscan binary published by
# https://github.com/cwayne18/vexscan.
ARG VEXSCAN_VERSION=latest
FROM ghcr.io/cwayne18/vexscan:${VEXSCAN_VERSION} AS vexscan

FROM alpine:3.20
RUN apk add --no-cache bash curl jq ca-certificates \
  && curl -fsSL -o /usr/local/bin/kubectl \
       "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/kubectl" \
  && chmod +x /usr/local/bin/kubectl

COPY --from=vexscan /usr/local/bin/vexscan /usr/local/bin/vexscan
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN addgroup -S vexscan && adduser -S -G vexscan vexscan
USER vexscan

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
