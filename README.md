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
- `paseo-pi-entrypoint.sh`:
  - seeds pi settings from `/opt/pi/agent/*.json` (mounted ConfigMap) into
    `$HOME/.pi/agent` on every start
  - clones/pulls `GIT_REPO_URL` into `/workspace/rpi` when set
  - execs the upstream `paseo-docker-entrypoint`

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
