# Paseo daemon + Pi coding agent (https://paseo.sh/docs/docker)
#
# Child image of the official Paseo image with the pi coding agent
# (@earendil-works/pi-coding-agent) installed, plus a small entrypoint that:
#   - seeds pi settings from /opt/pi/agent (mounted ConfigMap) into $HOME/.pi/agent
#   - clones the workspace repo (GIT_REPO_URL) into /workspace/rpi
# then hands off to the upstream paseo-docker-entrypoint.

FROM ghcr.io/getpaseo/paseo:latest

USER root

RUN npm install -g @earendil-works/pi-coding-agent@latest \
    && pi --version \
    && npm cache clean --force

COPY paseo-pi-entrypoint.sh /usr/local/bin/paseo-pi-entrypoint
RUN chmod +x /usr/local/bin/paseo-pi-entrypoint

ENV PASEO_PI_SETTINGS_DIR=/opt/pi/agent \
    WORKSPACE_DIR=/workspace \
    GIT_CLONE_DEPTH=1

EXPOSE 6767

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/paseo-pi-entrypoint"]
