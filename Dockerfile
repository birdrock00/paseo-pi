# Paseo daemon + Pi coding agent (https://paseo.sh/docs/docker)
#
# Child image of the official Paseo image with:
#   - the pi coding agent (@earendil-works/pi-coding-agent)
#   - kubectl (checksum-verified static binary) so the agent can drive this cluster
#   - python3 + pip + venv
#   - the Playwright MCP server driving headless Firefox
# plus a small entrypoint that:
#   - keeps the canonical home dotfiles in $PASEO_HOME/home and symlinks them into $HOME
#   - seeds pi settings from /opt/pi/agent (mounted ConfigMap) into $HOME/.pi/agent
#   - clones the workspace repo (GIT_REPO_URL) into /workspace/rpi
# then hands off to the upstream paseo-docker-entrypoint.
#
# SIZE NOTE: no browser build is baked in. See playwright-mcp-firefox.sh -
# the ~250 MB Firefox build is downloaded on first use into
# $PLAYWRIGHT_BROWSERS_PATH (persistent state volume). Only Firefox's OS
# libraries, which an unprivileged container cannot install later, are baked.

FROM ghcr.io/getpaseo/paseo:latest

USER root

# Must be set before any npm install that pulls in the `playwright` package,
# whose postinstall otherwise downloads chromium+firefox+webkit into the image.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_BROWSERS_PATH=/home/paseo/.paseo/playwright-browsers

# --- python3 + fetch tools -------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 --version \
    && python3 -m pip --version

# --- kubectl ---------------------------------------------------------------
# Static binary from the official release bucket, sha256-verified. Override the
# pin with --build-arg KUBECTL_VERSION=v1.37.1 (default: current stable).
ARG KUBECTL_VERSION=stable
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${KUBECTL_VERSION}" in \
      stable) ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" ;; \
      *) ver="${KUBECTL_VERSION}" ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl"; \
    curl -fsSL -o /tmp/kubectl.sha256 "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl.sha256"; \
    echo "$(awk '{print $1}' /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
    rm -f /tmp/kubectl.sha256; \
    chmod 0755 /usr/local/bin/kubectl; \
    kubectl version --client

# --- pi coding agent -------------------------------------------------------
RUN npm install -g @earendil-works/pi-coding-agent@latest \
    && pi --version \
    && npm cache clean --force

# --- Playwright MCP server -------------------------------------------------
RUN npm install -g @playwright/mcp@latest \
    && npm cache clean --force \
    && npm ls -g --depth=0 @playwright/mcp

# Firefox's OS-level shared libraries only. `install-deps` never touches the
# browser binary, and PLAYWRIGHT_BROWSERS_PATH is intentionally left empty so
# the last line (which fails the build if a browser ever sneaks in) stays true.
RUN set -eux; \
    groot="$(npm root -g)"; \
    pwcli="$groot/@playwright/mcp/node_modules/playwright-core/cli.js"; \
    [ -f "$pwcli" ] || pwcli="$groot/playwright-core/cli.js"; \
    node "$pwcli" install-deps firefox; \
    # install-deps pulls the full *headed* desktop stack. We only ever run
    # Firefox headless, so drop the X server and the software-GL driver: that
    # is xvfb + xserver-common + xfonts, and libgl1-mesa-dri which alone drags
    # in llvmpipe (libLLVM ~112 MB) and the DRI drivers (~25 MB).
    apt-get purge -y --auto-remove xvfb libgl1-mesa-dri libglx-mesa0; \
    apt-get autoremove --purge -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    ! ls -d "${PLAYWRIGHT_BROWSERS_PATH}"/* >/dev/null 2>&1

COPY playwright-mcp-firefox.sh /usr/local/bin/playwright-mcp-firefox
COPY paseo-pi-entrypoint.sh /usr/local/bin/paseo-pi-entrypoint
RUN chmod +x /usr/local/bin/playwright-mcp-firefox /usr/local/bin/paseo-pi-entrypoint

ENV PASEO_PI_SETTINGS_DIR=/opt/pi/agent \
    WORKSPACE_DIR=/workspace \
    GIT_CLONE_DEPTH=1

EXPOSE 6767

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/paseo-pi-entrypoint"]
