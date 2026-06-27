# NetBird Expose

A GitHub action that builds your project's Docker service on the runner and expose it through the **NetBird reverse proxy** — automatic TLS, optional auth, no port forwarding or firewall changes.

It runs after [`shaban00/netbird-connect`](https://github.com/shaban00/netbird-connect): once the runner is on the mesh, this action builds and starts your service, exposes it with `netbird expose`, holds it live for a configurable window, then deregisters the peer so nothing lingers.

## Usage

```yaml
name: expose-service
on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  expose:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.0.0
      - name: NetBird Connect
        uses: shaban00/netbird-connect@v1.0.0
        with:
          setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
          management-url: ${{ secrets.NETBIRD_MANAGEMENT_URL }}
          hostname: github-runner-${{ github.event.repository.name }}

      - name: NetBird Expose
        id: expose
        uses: shaban00/netbird-expose@v1.0.1
        with:
          port: "8080"
          app-env: ${{ secrets.APP_ENV }} # multiline secret, .env format
          expose-duration: "300"
          pin: ${{ secrets.EXPOSE_PIN }}
```

## How it works

1. Confirms the runner is connected to NetBird (run `netbird-connect` first).
2. Builds and starts your service — a **docker compose file takes precedence over a Dockerfile** when one exists on disk.
3. Runs `netbird expose <port>` in the background and reads back the public URL.
4. Holds the service live for `expose-duration` seconds.

## Prerequisites

- A **Linux** runner (e.g. `ubuntu-latest`) with Docker available.
- [`shaban00/netbird-connect`](https://github.com/shaban00/netbird-connect) run earlier in the job, so the runner is on the mesh.
- **Peer Expose enabled** by an account admin under **Settings → Clients**, with this peer's group allowed. Without it, `netbird expose` returns `permission denied`.
- The reverse proxy is a NetBird **v0.66+** feature. Self-hosted deployments need a separate `netbirdio/netbird-proxy` instance fronted by **Traefik** (the only proxy that provides the required TLS passthrough).

## Inputs

| Input             | Required | Default              | Description                                                                                        |
| ----------------- | -------- | -------------------- | -------------------------------------------------------------------------------------------------- |
| `port`            | yes      | —                    | Local port the service listens on (the target port to expose).                                     |
| `protocol`        | no       | `http`               | One of `http`, `https`, `tcp`, `udp`, `tls`.                                                       |
| `dockerfile`      | no       | `Dockerfile`         | Dockerfile path. Ignored when a compose file is present.                                           |
| `docker-compose`  | no       | `docker-compose.yml` | Compose file path. Takes precedence over the Dockerfile when this file exists.                     |
| `app-env`         | no       | `''`                 | Env vars to inject into the service, `KEY=VALUE` per line (`.env` format). Pass from a **secret**. |
| `expose-duration` | no       | `300`                | How long the service stays exposed, in seconds, before it is automatically torn down.              |
| `custom-domain`   | no       | `''`                 | Must already be configured and verified on your account.                                           |
| `external-port`   | no       | `''`                 | L4 public port on the proxy; auto-assigned on cloud.                                               |
| `name-prefix`     | no       | `''`                 | Readable prefix for the generated subdomain.                                                       |
| `password`        | no       | `''`                 | Pass from a **secret**.                                                                            |
| `pin`             | no       | `''`                 | 6-digit PIN. Pass from a **secret**.                                                               |
| `user-groups`     | no       | `''`                 | Comma-separated SSO groups allowed to access the service.                                          |
| `allow-ssh`       | no       | `false`              | Enable NetBird SSH access to the runner.                                                           |

## NetBird side setup

1. **Settings → Clients → Enable Peer Expose**: enable it, and add this runner's group to the allowed groups.
2. For a **custom domain**, configure and verify it on the account first (Reverse Proxy → Custom Domains).
