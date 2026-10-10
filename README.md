# paseo-pi

Paseo daemon (https://paseo.sh) Docker image with the
[pi coding agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
preinstalled, for use from the Paseo mobile (Android) app.

Built daily (and on push) by GitHub Actions and published to
`ghcr.io/birdrock00/paseo-pi` with `latest`, `mm-dd-YYYY`, branch and sha tags;
each build also creates a GitHub release.

## What's in the image

- `ghcr.io/getpaseo/paseo:latest` (Paseo daemon + bundled web UI on `:6767`)
- `@earendil-works/pi-coding-agent` installed globally (`pi`)
- `kubectl` - static release binary, sha256-verified. Pin it with
  `--build-arg KUBECTL_VERSION=v1.37.1` (default: current `stable`)
- `python3`, `python3-pip`, `python3-venv`
- `@playwright/mcp` + `playwright-mcp-firefox`, a launcher that serves the MCP
  server over headless Firefox (see below)
- `paseo-pi-entrypoint.sh`:
  - keeps the canonical home dotfiles (`.git-credentials`, `.gitconfig`,
    `.kube`) in `$PASEO_HOME/home` and symlinks them into `$HOME`, so operator
    credentials live in the state volume - never in the image and never in a
    repo checkout
  - creates `$PLAYWRIGHT_BROWSERS_PATH` (empty by default)
  - seeds pi settings from `/opt/pi/agent/*.json` (mounted ConfigMap) into
    `$HOME/.pi/agent` on every start
  - clones/pulls `GIT_REPO_URL` into `/workspace/rpi` when set
  - execs the upstream `paseo-docker-entrypoint`

## Headless Firefox without a 250 MB image penalty

`playwright-mcp-firefox` is what the agent's `mcp.json` points at:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "playwright-mcp-firefox",
      "args": ["--ignore-https-errors"]
    }
  }
}
```

It resolves the `playwright-core` CLI belonging to the *installed*
`@playwright/mcp`, and only if no Firefox build is present it runs
`playwright install firefox` and then execs the MCP server with
`--browser firefox --headless`.

**Yes - the browser really is fetched on demand, and that is the whole point.**
The image ships *no* browser build (`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` is set
before any npm install, so `playwright`'s postinstall cannot pull
chromium+firefox+webkit into a layer). The download goes to
`$PLAYWRIGHT_BROWSERS_PATH`, default `$PASEO_HOME/playwright-browsers`, which
lives on the persistent state volume - so it happens **once per volume**, not
once per image and not once per pod restart. A pod that never opens a browser
never downloads anything.

What *is* baked in, deliberately: Firefox's OS shared libraries. Those cannot be
fetched later because the MCP server runs as an unprivileged user and cannot
`apt-get`. `install-deps firefox` is then trimmed in the *same* layer, dropping
the headed-only desktop stack (`xvfb`, `xserver-common`, `xfonts`) and the
software-GL driver `libgl1-mesa-dri` with llvmpipe - ~180 MB that headless
Firefox does not need.

| variant | image size |
|---|---|
| base `ghcr.io/getpaseo/paseo` | 945 MB |
| + kubectl, python3, MCP, Firefox OS libs (no browser) | 1.54 GB |
| Firefox build, downloaded on demand at runtime | +~250 MB, on the state volume, once |

Knobs: `PLAYWRIGHT_MCP_HEADLESS=0` (headed), `PLAYWRIGHT_FIREFOX_AUTOINSTALL=0`
(fail instead of downloading), `PLAYWRIGHT_FIREFOX_PREWARM=1` (only ensure the
build is present, then exit - useful from an init container or a warm-up Job).

WebGL-requiring pages will not render (the GL driver is gone); everything else
about headless Firefox is unaffected.

## Run

```sh
docker run -d --name paseo-pi \
  -p 6767:6767 \
  -e PASEO_PASSWORD=change-me \
  -v paseo-home:/home/paseo \
  -v ./workspace:/workspace \
  ghcr.io/birdrock00/paseo-pi:latest
```

In Kubernetes this is deployed as a plain Deployment mounting two persistent
volumes at `/home/paseo` and `/workspace` (any ReadWrite-Many storage, e.g.
NFS), with the pi settings provided by a ConfigMap at `/opt/pi/agent` and
`PASEO_PASSWORD` from a Secret.
