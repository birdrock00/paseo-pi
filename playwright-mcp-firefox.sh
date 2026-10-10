#!/usr/bin/env bash
# Playwright MCP server, Firefox flavour, with ON-DEMAND browser download.
#
# The container image deliberately ships WITHOUT the Firefox build: it is
# ~100 MB compressed / ~250 MB unpacked and most pod restarts never open a
# browser. Only Firefox's OS-level shared libraries are baked in (they cannot
# be fetched later because the MCP server runs as an unprivileged user and
# cannot apt-get).
#
# The browser build itself is downloaded the first time an agent actually
# asks for a Firefox tool, into $PLAYWRIGHT_BROWSERS_PATH, which defaults to
# $PASEO_HOME/playwright-browsers. That lives on the persistent Paseo state
# volume, so it is downloaded once per volume - not once per image, and not
# once per pod restart.
#
# Usage (this is what the pi agent's mcp.json calls):
#   playwright-mcp-firefox [extra @playwright/mcp flags...]
#
# Env:
#   PLAYWRIGHT_BROWSERS_PATH   browser store (default $PASEO_HOME/playwright-browsers)
#   PLAYWRIGHT_MCP_HEADLESS    "0"/"false" to launch headed (default: headless)
#   PLAYWRIGHT_FIREFOX_AUTOINSTALL  "0" to fail instead of downloading
#   PLAYWRIGHT_FIREFOX_PREWARM "1" to only ensure the browser is present, then exit
set -euo pipefail

log() { printf '[playwright-mcp-firefox] %s\n' "$*" >&2; }

: "${PASEO_HOME:=${HOME:-/home/paseo}/.paseo}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$PASEO_HOME/playwright-browsers}"

# Resolve the playwright-core CLI that belongs to the *installed* @playwright/mcp
# so the Firefox revision we download is exactly the one MCP will launch.
GROOT="$(npm root -g)"
PWCLI="$GROOT/@playwright/mcp/node_modules/playwright-core/cli.js"
[[ -f "$PWCLI" ]] || PWCLI="$GROOT/playwright-core/cli.js"
[[ -f "$PWCLI" ]] || { log "ERROR: playwright-core CLI not found under $GROOT"; exit 1; }

firefox_binary() {
  shopt -s nullglob
  local c
  for c in "$PLAYWRIGHT_BROWSERS_PATH"/firefox-*/firefox/firefox; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

install_firefox() {
  log "Firefox build missing - downloading into $PLAYWRIGHT_BROWSERS_PATH (~100 MB, once per volume)"
  mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
  if ! node "$PWCLI" install firefox >&2; then
    log "ERROR: Firefox download failed. Check egress to cdn.playwright.dev and retry."
    return 1
  fi
  log "Firefox build ready"
}

if [[ ! -x "$(firefox_binary || true)" ]]; then
  if [[ "${PLAYWRIGHT_FIREFOX_AUTOINSTALL:-1}" == "0" ]]; then
    log "ERROR: Firefox is not installed and PLAYWRIGHT_FIREFOX_AUTOINSTALL=0."
    log "       Run: playwright-mcp-firefox --prewarm  (or: node $PWCLI install firefox)"
    exit 1
  fi
  install_firefox
fi

# --prewarm: caller only wanted the download (e.g. a warm-up Job or init step).
if [[ "${PLAYWRIGHT_FIREFOX_PREWARM:-0}" == "1" ]]; then
  log "prewarm complete: $(firefox_binary)"
  exit 0
fi

MCP_CLI="$GROOT/@playwright/mcp/cli.js"
[[ -f "$MCP_CLI" ]] || { log "ERROR: @playwright/mcp CLI not found at $MCP_CLI"; exit 1; }

ARGS=(--browser firefox)
case "${PLAYWRIGHT_MCP_HEADLESS:-1}" in
  0 | false | no | off) ;;
  *) ARGS+=(--headless) ;;
esac

exec node "$MCP_CLI" "${ARGS[@]}" "$@"
