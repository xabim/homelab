# syntax=docker/dockerfile:1
# =============================================================================
# homelab/paperclip - pinned upstream Paperclip image + generic agent tooling
#
#   * Playwright's Chromium and its system libraries (browser tests)
#   * ffmpeg, zip, unzip
#
# Everything else (Node, git, claude CLI, gh, ripgrep, tini) comes from the
# pinned upstream image. Build: see ../README.md "Build the image".
# =============================================================================
ARG PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip:sha-d69631b01b9c658f80bf8bed389863dce82643e1
FROM ${PAPERCLIP_IMAGE}

ARG PLAYWRIGHT_VERSION
USER root

# Browsers live outside $HOME so the bind-mounted /paperclip stays small.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg zip unzip \
 && npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium \
 && chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}" \
 && rm -rf /var/lib/apt/lists/* /root/.npm

# Claude Code managed settings are bind-mounted read-only at runtime
# (../config/claude/); create the parents so the mounts have somewhere to go.
RUN mkdir -p /etc/claude-code/managed-settings.d /workspaces /etc/ssl/homelab

# Forgejo plugin skills push with `gitf` ("git with a Forgejo credential").
# Plain git already has one here (env-only credential helper in the compose
# file), so gitf is just git.
RUN printf '#!/bin/sh\nexec git "$@"\n' > /usr/local/bin/gitf && chmod 755 /usr/local/bin/gitf

# The compose file runs this image as ${PUID}:${PGID}; the upstream
# entrypoint detects a non-root start and execs the server directly.
USER node
