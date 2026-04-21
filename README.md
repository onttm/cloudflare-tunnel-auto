# deployrr-cloudflare-tunnel

A [Deployrr](https://github.com/SimpleHomelab/Deployrr) community app that runs a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) alongside your existing Traefik stack — no open inbound ports on your router required.

## What it does

- Creates a secure, outbound-only connection from your server to Cloudflare's edge
- Automatically generates **wildcard ingress rules** for every domain in your `.env` (`DOMAINNAME_1`, `DOMAINNAME_2`, ...)
- Routes `*.yourdomain.com` traffic through Traefik, which handles service routing
- Your home IP never appears in public DNS — Cloudflare's IPs do instead

## Architecture

The app uses two services:

```
cloudflare-tunnel-init  (alpine, runs once at compose-up)
  └── decodes CLOUDFLARE_TUNNEL_TOKEN
  └── loops through DOMAINNAME_1, DOMAINNAME_2, ...
  └── writes config.yml + creds.json to a named volume
  └── exits

cloudflare-tunnel  (cloudflare/cloudflared, long-lived)
  └── reads config from shared volume
  └── runs the tunnel
```

`cloudflare/cloudflared:latest` is a distroless image with no shell. The Alpine init container handles all config templating so `cloudflared` never needs one.

## Prerequisites

1. **Cloudflare account** with your domain(s) on Cloudflare DNS
2. **Traefik** running and bound to `localhost:443` (standard Deployrr setup)
3. A **Cloudflare Tunnel** created in Zero Trust → Networks → Tunnels
4. The tunnel **token** from the tunnel's Configure page

## Installation

### 1. Create a Cloudflare Tunnel

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com):

1. Go to **Networks → Tunnels → Create a tunnel**
2. Choose **Cloudflared** as the connector type
3. Name it (e.g. `homelab` or your server name)
4. Copy the tunnel token shown on the next screen

> **Do not configure Public Hostnames in the dashboard.** The init container manages ingress rules locally using wildcard rules that the dashboard UI does not support. Leave the routes tab empty.

### 2. Add to your stack via deployrr-tools

```bash
deployrr-tools.sh --scaffold https://github.com/onttm/deployrr-cloudflare-tunnel
```

Or clone manually:

```bash
git clone https://github.com/onttm/deployrr-cloudflare-tunnel \
  /opt/deployrr-tools/community-apps/cloudflare-tunnel
```

### 3. Add the tunnel token to `.env`

```bash
echo "CLOUDFLARE_TUNNEL_TOKEN='<paste your token here>'" | sudo tee -a ~/docker/.env
```

`DOMAINNAME_1` must already be in your `.env` — it is a standard Deployrr variable.

### 4. Install via deployrr-tools

```bash
deployrr-tools.sh
# Select: Browse & install a Deployrr community app → cloudflare-tunnel
```

## Multiple domains

Add domains to `.env` and restart:

```bash
# In ~/docker/.env:
DOMAINNAME_1='yourdomain.com'
DOMAINNAME_2='seconddomain.com'
DOMAINNAME_3='thirddomain.com'
```

Then force-recreate both services so the init container reruns and regenerates the config:

```bash
docker compose -f ~/docker/docker-compose-plexy.yml up -d \
  --force-recreate cloudflare-tunnel-init cloudflare-tunnel
```

## The 100 MB limit

Cloudflare enforces a **100 MB request body limit** on all proxied (orange-cloud) traffic. This affects:

- **Nextcloud / Immich** — large file uploads will fail
- **Frigate** — live RTSP/WebRTC streams should stay on LAN

**Workaround:** Use grey-cloud (DNS-only) records for those services so traffic bypasses the proxy and hits your IP directly.

## Troubleshooting

**Check tunnel startup and domain config:**
```bash
docker logs cloudflare-tunnel-init
docker logs cloudflare-tunnel | grep -E 'Tunnel|Registered|ERROR'
```

**Subdomains return 404 even though the tunnel is up:**
Verify your Cloudflare DNS records are **proxied (orange cloud)**. Grey-cloud records bypass the tunnel routing.

**`ERROR: Could not decode CLOUDFLARE_TUNNEL_TOKEN`:**
Re-copy the token from Cloudflare dashboard → Zero Trust → Networks → Tunnels → your tunnel → Configure.

**Config not updating after adding a new domain:**
The init container only reruns on `--force-recreate`. Run:
```bash
docker compose -f ~/docker/docker-compose-plexy.yml up -d \
  --force-recreate cloudflare-tunnel-init cloudflare-tunnel
```

**Services unreachable after enabling the tunnel:**
Verify Traefik is listening on port 443. The tunnel forwards to `localhost:443` with TLS verification disabled (local self-signed cert is expected).

## Compatibility

- Tested with Deployrr v6.0
- Requires Docker Compose v2.23+ (inline `configs` support)
- Requires `cloudflare/cloudflared:latest`

## Related community apps

- [deployrr-cf-companion](https://github.com/onttm/deployrr-tools) — auto-creates Cloudflare CNAME records for every Traefik service (pairs well with this tunnel)
