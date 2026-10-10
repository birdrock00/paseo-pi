#!/usr/bin/env bash
set -euo pipefail

log() { echo "[paseo-pi] $*"; }

PI_AGENT_DIR="${HOME:-/home/paseo}/.pi/agent"

# Run file operations as the paseo user when started as root (the upstream
# entrypoint also drops to paseo via gosu). chown across the NFS export can
# fail with EINVAL, so we never create root-owned files in the mounted home
# or workspace in the first place.
if [[ "$(id -u)" == "0" ]]; then
  as_user() { gosu paseo "$@"; }
else
  as_user() { "$@"; }
fi

# Pre-create the state directories the upstream entrypoint expects, as the
# paseo user. The upstream ensure_dir only chowns root-owned dirs, and chown
# fails over this NFS export, so directories must never be created as root.
for d in "${HOME:-/home/paseo}" "${PASEO_HOME:-${HOME:-/home/paseo}/.paseo}" \
         "${CLAUDE_CONFIG_DIR:-${HOME:-/home/paseo}/.claude}" \
         "${CODEX_HOME:-${HOME:-/home/paseo}/.codex}" \
         "${XDG_CONFIG_HOME:-${HOME:-/home/paseo}/.config}" \
         "${XDG_DATA_HOME:-${HOME:-/home/paseo}/.local/share}" \
         "${XDG_STATE_HOME:-${HOME:-/home/paseo}/.local/state}" \
         "${XDG_CACHE_HOME:-${HOME:-/home/paseo}/.cache}"; do
  as_user mkdir -p "$d" || log "WARNING: could not pre-create $d"
done

# 0. Home layout: the canonical home dotfiles live in a `home` subdir inside
#    the Paseo state directory ($PASEO_HOME/home) and $HOME only holds
#    symlinks to them. Keeps credentials/kubeconfig in one obviously-stateful
#    place, outside any repo checkout, and never in the image.
STATE_HOME="${PASEO_HOME:-${HOME:-/home/paseo}/.paseo}/home"
as_user mkdir -p "$STATE_HOME"
for f in .git-credentials .gitconfig .kube; do
  real="${HOME:-/home/paseo}/$f"
  # One-time migration: anything already sitting in $HOME becomes canonical in
  # the state dir, so re-running this never destroys an operator's setup.
  if [[ -e "$real" && ! -L "$real" && ! -e "$STATE_HOME/$f" ]]; then
    as_user mv "$real" "$STATE_HOME/$f" && log "moved $real into $STATE_HOME"
  fi
  [[ -e "$STATE_HOME/$f" ]] || continue
  as_user ln -sfn "$STATE_HOME/$f" "$real" \
    && log "linked $real -> $STATE_HOME/$f" \
    || log "WARNING: could not symlink $real"
done

# Playwright browser store (see playwright-mcp-firefox.sh). Deliberately empty
# in the image; the Firefox build lands here on first use and survives restarts.
if [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
  as_user mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" \
    || log "WARNING: could not create $PLAYWRIGHT_BROWSERS_PATH"
fi

# 1. Seed pi settings from the ConfigMap mounted at /opt/pi/agent. Files are
#    copied on every start so the
#    declared settings stay canonical; sessions/auth on the persistent home win
#    only when the ConfigMap does not provide the file.
if [[ -d "${PASEO_PI_SETTINGS_DIR:-/opt/pi/agent}" ]]; then
  as_user mkdir -p "$PI_AGENT_DIR"
  for f in "${PASEO_PI_SETTINGS_DIR:-/opt/pi/agent}"/*.json; do
    [[ -e "$f" ]] || continue
    as_user cp -f "$f" "$PI_AGENT_DIR/$(basename "$f")" \
      && log "seeded pi setting $(basename "$f")" \
      || log "WARNING: failed to seed $(basename "$f")"
  done
fi

# 2. Clone the workspace repo (GIT_REPO_URL) if requested and not present.
if [[ -n "${GIT_REPO_URL:-}" ]]; then
  target="${WORKSPACE_DIR:-/workspace}/rpi"
  as_user mkdir -p "${WORKSPACE_DIR:-/workspace}"
  if [[ -d "$target/.git" ]]; then
    log "refreshing workspace $target"
    as_user bash -c "cd '$target' && git pull --ff-only" 2>/dev/null \
      || log "git pull failed; keeping existing checkout"
  else
    log "cloning $GIT_REPO_URL into $target"
    as_user git clone --depth "${GIT_CLONE_DEPTH:-1}" "$GIT_REPO_URL" "$target" \
      || log "WARNING: git clone failed; starting paseo without workspace checkout"
  fi
fi

# 3. Hand off to the upstream Paseo entrypoint.
exec /usr/local/bin/paseo-docker-entrypoint "$@"
