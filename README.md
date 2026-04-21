# cloudflare-tunnel-auto

A fully API-automated [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — no dashboard setup, no manual DNS records, no token pasting. The tunnel, DNS, and config are created automatically via the Cloudflare API and managed locally. Set it and forget it.

Works with any Docker Compose stack. Compatible with [Deployrr](https://github.com/SimpleHomelab/Deployrr) via [deployrr-tools](https://github.com/onttm/deployrr-tools).

> **How is this different from the official Deployrr cloudflare-tunnel app?**
> The official app requires you to create the tunnel manually in the Cloudflare dashboard and paste a token. This app does all of that for you via the Cloudflare API — including wildcard DNS records that the dashboard UI does not support.

## What it does

On first run, the init container fully automates setup:

1. Creates a locally-managed Cloudflare Tunnel via the Cloudflare API
2. Adds wildcard DNS records (`*.yourdomain.com`) for every `DOMAINNAME_N` in your `.env`
3. Generates the `cloudflared` config with wildcard ingress rules
4. Exits — the main tunnel service takes over

On subsequent runs it verifies the tunnel is still active, updates DNS and config if domains changed, and exits cleanly. **No manual tunnel creation, DNS setup, or dashboard configuration required.**

## Architecture

```
cloudflare-tunnel-auto-init  (Alpine, runs once at compose-up)
  ├── reads cf_dns_api_token Docker secret
  ├── calls Cloudflare API to create tunnel (idempotent)
  ├── creates *.domain CNAME records for each DOMAINNAME_N
  ├── writes config.yml + creds.json to a named volume
  └── exits

cloudflare-tunnel-auto  (cloudflare/cloudflared, long-lived)
  ├── waits for init to complete successfully
  ├── reads config from shared named volume
  └── runs the tunnel (4 redundant connections to Cloudflare edge)
```

`cloudflare/cloudflared:latest` is a distroless image with no shell. The Alpine init container handles all API calls and config generation so `cloudflared` never needs one.

## Prerequisites

- **Cloudflare account** with your domain(s) managed on Cloudflare DNS
- **A reverse proxy** (Traefik, nginx, Caddy, etc.) listening on `localhost:443` — the tunnel forwards all traffic there
- A **Cloudflare Account API token** with two permissions:
  - `Zone → DNS → Edit` (all zones, or scoped to your specific domains)
  - `Account → Cloudflare One Connectors → Edit`

## Installation

### 1. Create a Cloudflare Account API token

> Use an **Account API token**, not a User API token — it is not tied to your login and is safer for server use.

In the [Cloudflare dashboard](https://dash.cloudflare.com) → **Account Home** → **Manage Account** → **API Tokens** → **Create Token**:

| Permission | Resource | Access |
|---|---|---|
| Zone → DNS | All zones | Edit |
| Account → Cloudflare One Connectors | Your account | Edit |

Copy the token value — Cloudflare only shows it once.

### 2. Clone the repo

```bash
git clone https://github.com/onttm/cloudflare-tunnel-auto
cd cloudflare-tunnel-auto
```

### 3. Create the secret file

The token is stored as a file-based Docker secret — never in an environment variable or `.env`.

```bash
mkdir -p secrets
printf '%s' 'your-token-here' > secrets/cf_dns_api_token
chmod 600 secrets/cf_dns_api_token
```

> Use `printf '%s'` rather than `echo` to avoid writing a trailing newline into the token file.

### 4. Create your `.env` file

```bash
cat > .env <<EOF
DOMAINNAME_1=yourdomain.com
# DOMAINNAME_2=seconddomain.com   # optional
# CLOUDFLARE_TUNNEL_NAME=homelab  # optional, defaults to homelab
EOF
```

### 5. Start the tunnel

```bash
docker compose up -d
```

> The `profiles:` line in `compose.yml` is commented out by default for standalone use. Deployrr users should uncomment it to integrate with their stack profiles.

The init container runs, creates the tunnel and DNS records, and exits. The tunnel service starts and connects to Cloudflare's edge. Check progress with:

```bash
docker logs cloudflare-tunnel-auto-init
docker logs cloudflare-tunnel-auto | grep Registered
```

---

## Deployrr users

If you are running a [Deployrr](https://github.com/SimpleHomelab/Deployrr) stack, use the provided `install.sh` instead. It reads your existing `.env` and secrets, registers the app in your stack, and starts the tunnel automatically:

```bash
bash install.sh
```

### Deployrr community registry

To contribute this app to the Deployrr community registry via [deployrr-tools](https://github.com/onttm/deployrr-tools):

```bash
deployrr-tools.sh
# Select: 2) Prep new community app from GitHub
# Enter:  https://github.com/onttm/cloudflare-tunnel-auto
```

## Multiple domains

Add domains to `.env`:

```bash
# In ~/docker/.env:
DOMAINNAME_1='yourdomain.com'
DOMAINNAME_2='seconddomain.com'
DOMAINNAME_3='thirddomain.com'
```

The init container reads `DOMAINNAME_1`, `DOMAINNAME_2`, `DOMAINNAME_3`... in sequence and stops when it reaches an unset variable. No hardcoded limit — add as many as you need.

The compose file passes `DOMAINNAME_1` through `DOMAINNAME_5` by default. To use more, add them to the `environment:` block in `compose.yml`:

```yaml
environment:
  - DOMAINNAME_6
  - DOMAINNAME_7
```

Then force-recreate both services so the init container reruns:

```bash
docker compose up -d --force-recreate cloudflare-tunnel-auto-init cloudflare-tunnel-auto
```

## DNS behaviour

For each domain the init container creates:

- `*.yourdomain.com → <tunnel-id>.cfargotunnel.com` (proxied)
- `yourdomain.com → <tunnel-id>.cfargotunnel.com` (proxied, only if no conflicting records exist)

The root domain record is skipped automatically if the zone already has MX or A records (common when a domain has email configured). The wildcard record covers all subdomains — the root record is rarely needed.

## The 100 MB limit

Cloudflare enforces a **100 MB request body limit** on all proxied (orange-cloud) traffic. This affects:

- **Nextcloud / Immich** — large file uploads will fail silently
- **Frigate** — live video streams should stay on LAN

**Workaround:** Use grey-cloud (DNS-only) CNAME records for those services. Traffic bypasses the Cloudflare proxy and hits your IP directly (requires open ports for those services only).

## Troubleshooting

**Check tunnel startup and domain config:**
```bash
docker logs cloudflare-tunnel-auto-init
docker logs cloudflare-tunnel-auto | grep -E 'Registered|ERR'
```

**Subdomains return 404:**
Verify Cloudflare DNS records are **proxied (orange cloud)**. Grey-cloud records bypass tunnel routing.

**`ERROR: Cloudflare API token not found`:**
Ensure `secrets/cf_dns_api_token` exists in your working directory and is mode `600`:
```bash
ls -la secrets/cf_dns_api_token
```

**`ERROR: DOMAINNAME_1 is not set`:**
Ensure `DOMAINNAME_1=yourdomain.com` is in your `.env` file.

**Config not updating after adding a new domain:**
The init container only reruns on `--force-recreate`:
```bash
docker compose up -d --force-recreate cloudflare-tunnel-auto-init cloudflare-tunnel-auto
```

**Services unreachable after enabling the tunnel:**
Verify your reverse proxy is listening on `localhost:443`. The tunnel forwards all traffic there with TLS verification disabled (self-signed cert is fine).

## Compatibility

- Tested with Deployrr v6.0
- Requires Docker Compose v2.20+
- Requires `cloudflare/cloudflared:latest`
- Runs on `linux/amd64` and `linux/arm64`
