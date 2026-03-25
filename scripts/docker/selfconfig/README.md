# Self-configuring Container

A zero-setup Docker deployment for OpenClaw. All initialization logic that
`scripts/docker/setup.sh` runs on the host is moved **inside** the container's
entrypoint, enabling true one-click startup.

## Files

| File               | Purpose                                                  |
|--------------------|----------------------------------------------------------|
| `Dockerfile`       | Multi-stage build; adds `gosu` + `entrypoint.sh` on top  |
| `entrypoint.sh`    | Container entrypoint — 6-phase auto-initialization       |
| `docker-compose.yml` | Compose file with sane defaults and named volumes      |

## Quick Start

### Option A: Docker Compose (recommended)

```bash
# Build the self-configuring image (from repo root)
docker build -f scripts/docker/selfconfig/Dockerfile -t openclaw:selfconfig .

# One-click start (zero configuration)
OPENCLAW_IMAGE=openclaw:selfconfig \
  docker compose -f scripts/docker/selfconfig/docker-compose.yml up -d

# View logs
docker compose -f scripts/docker/selfconfig/docker-compose.yml logs -f
```

### Option B: Docker Run (single command)

```bash
# Build (same as above)
docker build -f scripts/docker/selfconfig/Dockerfile -t openclaw:selfconfig .

# Run with named volumes (simplest — data persists across restarts)
docker run -d \
  --name openclaw-gateway \
  --init \
  --restart unless-stopped \
  -p 18789:18789 \
  -p 18790:18790 \
  -v openclaw-config:/home/node/.openclaw \
  -v openclaw-workspace:/home/node/.openclaw/workspace \
  openclaw:selfconfig

# Run with host-path bind mount (access config from host)
docker run -d \
  --name openclaw-gateway \
  --init \
  --restart unless-stopped \
  -p 18789:18789 \
  -p 18790:18790 \
  -v "$HOME/.openclaw:/home/node/.openclaw" \
  openclaw:selfconfig

# Run with workspace on a separate host path (e.g. larger disk)
docker run -d \
  --name openclaw-gateway \
  --init \
  --restart unless-stopped \
  -p 18789:18789 \
  -p 18790:18790 \
  -v "$HOME/.openclaw:/home/node/.openclaw" \
  -v "/data/openclaw-workspace:/home/node/.openclaw/workspace" \
  openclaw:selfconfig

# Run with a pre-set token
docker run -d \
  --name openclaw-gateway \
  --init \
  --restart unless-stopped \
  -p 18789:18789 \
  -p 18790:18790 \
  -e OPENCLAW_GATEWAY_TOKEN=your-secret-token \
  -v openclaw-config:/home/node/.openclaw \
  -v openclaw-workspace:/home/node/.openclaw/workspace \
  openclaw:selfconfig

# Run with sandbox enabled (requires Docker socket)
docker run -d \
  --name openclaw-gateway \
  --init \
  --restart unless-stopped \
  -p 18789:18789 \
  -p 18790:18790 \
  -e OPENCLAW_SANDBOX=1 \
  -v openclaw-config:/home/node/.openclaw \
  -v openclaw-workspace:/home/node/.openclaw/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  openclaw:selfconfig

# Run with custom timezone and loopback bind
docker run -d \
  --name openclaw-gateway \
  --init \
  --restart unless-stopped \
  --network host \
  -e OPENCLAW_GATEWAY_BIND=loopback \
  -e TZ=Asia/Shanghai \
  -v openclaw-config:/home/node/.openclaw \
  -v openclaw-workspace:/home/node/.openclaw/workspace \
  openclaw:selfconfig
```

### Management Commands (docker run)

```bash
# View logs
docker logs -f openclaw-gateway

# Run an ad-hoc CLI command
docker exec -it openclaw-gateway node dist/index.js channels login

# Check health
docker exec openclaw-gateway node dist/index.js health

# Stop
docker stop openclaw-gateway

# Start again (entrypoint self-heals on restart)
docker start openclaw-gateway

# Remove and recreate
docker rm -f openclaw-gateway
# Then re-run any of the docker run commands above
```

## What the Entrypoint Does

On every container start, `entrypoint.sh` automatically runs:

1. **Fix permissions** — chowns bind-mounted config dirs to `node:node` (as root)
2. **Resolve token** — reads from config, env, or auto-generates a new one
3. **Drop privileges** — re-execs as `node` user via `gosu`
4. **Run onboarding** — `openclaw onboard --mode local --no-install-daemon`
5. **Sync config** — pins `gateway.mode=local` and `gateway.bind`
6. **Start gateway** — `exec node dist/index.js gateway --bind ... --port 18789`

## Environment Variables

All optional; sane defaults are provided:

| Variable                     | Default    | Description                              |
|------------------------------|------------|------------------------------------------|
| `OPENCLAW_GATEWAY_TOKEN`     | (generated)| Pre-shared auth token                    |
| `OPENCLAW_GATEWAY_BIND`      | `lan`      | `lan` (0.0.0.0) or `loopback`           |
| `OPENCLAW_GATEWAY_PORT`      | `18789`    | Host-facing gateway port                 |
| `OPENCLAW_BRIDGE_PORT`       | `18790`    | Host-facing bridge port                  |
| `OPENCLAW_CONFIG_DIR`        | (volume)   | Host path or named volume for config     |
| `OPENCLAW_WORKSPACE_DIR`     | (volume)   | Host path or named volume for workspace  |
| `OPENCLAW_SANDBOX`           | (off)      | `1` to enable sandbox isolation          |
| `OPENCLAW_SKIP_ONBOARD`      | `1`        | `1` to skip onboarding                   |
| `OPENCLAW_TZ`                | `UTC`      | IANA timezone                            |

## Ad-hoc CLI Commands

No separate `openclaw-cli` service is needed. Use `docker compose exec` against
the running gateway container:

```bash
# Add a Telegram channel
docker compose -f scripts/docker/selfconfig/docker-compose.yml \
  exec openclaw-gateway node dist/index.js channels add --channel telegram --token <token>

# WhatsApp QR login
docker compose -f scripts/docker/selfconfig/docker-compose.yml \
  exec openclaw-gateway node dist/index.js channels login

# Check health
docker compose -f scripts/docker/selfconfig/docker-compose.yml \
  exec openclaw-gateway node dist/index.js health
```

## vs. Original `setup.sh`

| Aspect              | `setup.sh` (original)                    | Self-configuring (this)               |
|---------------------|------------------------------------------|---------------------------------------|
| Host prerequisites  | Bash, Docker, Python/Node on host        | Docker only                           |
| Setup steps         | Run `setup.sh` → multiple `docker run`   | `docker compose up -d`                |
| Permission fix      | Host runs temp container as root         | Entrypoint does it automatically      |
| Token management    | Host script reads/generates/writes .env  | Entrypoint auto-detects or generates  |
| Config sync         | Host runs `docker compose run` CLI       | Entrypoint runs CLI internally        |
| Sandbox setup       | Host builds overlay compose + config     | Entrypoint auto-detects docker.sock   |
| Restart behavior    | Manual re-setup needed                   | Self-heals on every restart           |
