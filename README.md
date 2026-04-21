# deployrr-cloudflare-tunnel

A [Deployrr](https://github.com/SimpleHomelab/Deployrr) community app that runs a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) alongside your existing Traefik stack — no open inbound ports on your router required.

## What it does

- Creates a secure, outbound-only connection from your server to Cloudflare's edge
- Automatically generates wildcard ingress rules for **every domain** defined in your `.env` (`DOMAINNAME_1`, `DOMAINNAME_2`, ...)
- Routes all subdomain traffic (`*.yourdomain.com`) through to Traefik, which handles the actual service routing
- Your home IP is never exposed in public DNS — Cloudflare's IPs appear instead

## How it works

At container startup, the bundled entrypoint script:

1. Decodes `CLOUDFLARE_TUNNEL_TOKEN` to extract the tunnel ID and credentials
2. Loops through `DOMAINNAME_1`, `DOMAINNAME_2`, etc. from your `.env`
3. Generates a `cloudflared` config with wildcard ingress rules for each domain
4. Starts `cloudflared` pointed at `localhost:443` (your Traefik instance)

No hardcoded domain names. No config files to manually edit. Adding a new domain means adding `DOMAINNAME_N` to `.env` and restarting the container.

## Prerequisites

1. **Cloudflare account** with your domain(s) on Cloudflare DNS
2. **Traefik** running and bound to `localhost:443` (standard Deployrr setup)
3. A **Cloudflare Tunnel** created in Zero Trust → Networks → Tunnels
4. The tunnel **token** (copied from the tunnel's Configure page)

## Installation

### 1. Create a Cloudflare Tunnel

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com):

1. Go to **Networks → Tunnels → Create a tunnel**
2. Choose **Cloudflared** as the connector type
3. Name it (e.g. `plexy` or `homelab`)
4. Copy the tunnel token shown on the next screen — you'll need it in step 3

> You do **not** need to configure any Public Hostnames in the dashboard. The entrypoint script manages ingress rules locally, which supports wildcards (`*.yourdomain.com`) that the dashboard UI does not.

### 2. Add to your stack via deployrr-tools

```bash
deployrr-tools.sh --scaffold https://github.com/onttm/deployrr-cloudflare-tunnel
```

Or clone manually into your `community-apps` directory:

```bash
git clone https://github.com/onttm/deployrr-cloudflare-tunnel \
  /opt/deployrr-tools/community-apps/cloudflare-tunnel
```

### 3. Add required variable to `.env`

```bash
echo "CLOUDFLARE_TUNNEL_TOKEN='<paste your token here>'" | sudo tee -a ~/docker/.env
```

`DOMAINNAME_1` must already be present in your `.env` — it is a standard Deployrr variable.

### 4. Install via deployrr-tools

```bash
deployrr-tools.sh
# Select: Browse & install a Deployrr community app → cloudflare-tunnel
```

## Multiple domains

Define additional domains in your `.env` and the tunnel will cover all of them:

```bash
DOMAINNAME_1='yourdomain.com'
DOMAINNAME_2='seconddomain.com'
DOMAINNAME_3='thirddomain.com'
```

Restart the container after adding new domains:

```bash
docker restart cloudflare-tunnel
```

## The 100 MB limit

Cloudflare enforces a **100 MB request body limit** on all proxied (orange-cloud) traffic. This affects:

- **Nextcloud / Immich** — large file uploads will fail
- **Frigate** — live RTSP/WebRTC streams should stay on LAN

**Workaround:** Use grey-cloud (DNS-only) records for those services so traffic bypasses the Cloudflare proxy and hits your IP directly. Everything else routes through the tunnel normally.

## Troubleshooting

**Check tunnel status and ingress rules:**
```bash
docker logs cloudflare-tunnel | grep -E 'Tunnel ID|domain|ERROR|Registered'
```

**Tunnel connected but subdomains return 404:**
Make sure your domain's DNS records are **proxied (orange cloud)** in Cloudflare. Grey-cloud records bypass the tunnel.

**`ERROR: Could not decode CLOUDFLARE_TUNNEL_TOKEN`:**
The token value in `.env` is malformed. Re-copy it from the Cloudflare dashboard (Zero Trust → Networks → Tunnels → your tunnel → Configure).

**Services unreachable after enabling tunnel:**
Verify Traefik is listening on port 443. The tunnel connects to `localhost:443` with TLS verification disabled (self-signed cert is fine).

## Compatibility

- Tested with Deployrr v5.11+
- Requires Docker Compose v2.23+ (for inline `configs` support)
- Requires `cloudflare/cloudflared:latest`

## Related community apps

- [deployrr-cf-companion](https://github.com/onttm/deployrr-tools) — auto-creates Cloudflare CNAME records for every Traefik service (pairs well with this tunnel)
