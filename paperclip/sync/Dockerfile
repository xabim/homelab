# syntax=docker/dockerfile:1
# =============================================================================
# homelab/studio-sync - the smallest thing that can run config/sync/studio-sync.sh:
# busybox sh + curl + jq on Alpine (about 15 MB). No git, no Docker, no Node.
# Build: see ../README.md "Build the image".
# =============================================================================
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}
RUN apk add --no-cache curl jq
USER 65534:65534
ENTRYPOINT ["/bin/sh", "/studio-sync.sh"]
