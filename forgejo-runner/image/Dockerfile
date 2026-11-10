# syntax=docker/dockerfile:1
# =============================================================================
# homelab/forgejo-runner - Forgejo Actions runner (host mode, no Docker).
#
# Jobs run in "host" mode, i.e. directly inside THIS container: no Docker
# socket, no Docker-in-Docker, no privileged mode. The base image already has
# Node.js and Playwright's Chromium with its system libraries, so web
# projects' checks (incl. browser tests) work out of the box.
# Keep PLAYWRIGHT_VERSION equal to the projects' @playwright/test version.
# =============================================================================
ARG PLAYWRIGHT_VERSION=1.64.1
ARG RUNNER_VERSION=13.2.0
FROM code.forgejo.org/forgejo/runner:${RUNNER_VERSION} AS runner

FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends git zip unzip ffmpeg tini \
 && rm -rf /var/lib/apt/lists/*
COPY --from=runner /bin/forgejo-runner /usr/local/bin/forgejo-runner
COPY entrypoint.sh /usr/local/bin/ci-runner-entrypoint
RUN chmod 755 /usr/local/bin/ci-runner-entrypoint && mkdir -p /data && chmod 777 /data
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ci-runner-entrypoint"]
CMD ["forgejo-runner", "daemon", "--config", "/etc/forgejo-runner/config.yml"]
