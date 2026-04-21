#!/bin/sh
set -e

CF_API="https://api.cloudflare.com/client/v4"
CREDS_FILE=/etc/cloudflared/creds.json
CONFIG_FILE=/etc/cloudflared/config.yml
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-homelab}"

# ── Load API token from Docker secret or env var ─────────────────────────────
CF_TOKEN=$(cat /run/secrets/cf_dns_api_token 2>/dev/null || true)
if [ -z "$CF_TOKEN" ] && [ -n "$CF_API_TOKEN" ]; then
  CF_TOKEN="$CF_API_TOKEN"
fi

# ── Validate ─────────────────────────────────────────────────────────────────
if [ -z "$CF_TOKEN" ]; then
  echo "ERROR: Cloudflare API token not found." >&2
  echo "       Mount cf_dns_api_token as a Docker secret, or set CF_API_TOKEN." >&2
  echo "       Token requires: Zone:DNS:Edit + Cloudflare Tunnel:Edit" >&2
  exit 1
fi
if [ -z "$DOMAINNAME_1" ]; then
  echo "ERROR: DOMAINNAME_1 is not set in your .env" >&2
  exit 1
fi

# ── Cloudflare API helper ─────────────────────────────────────────────────────
cf() {
  METHOD="$1"; shift
  URL="$1"; shift
  curl -sf -X "$METHOD" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "$URL" "$@"
}

check_success() {
  RESPONSE="$1"
  CONTEXT="$2"
  if [ "$(echo "$RESPONSE" | jq -r '.success')" != "true" ]; then
    echo "ERROR: $CONTEXT failed:" >&2
    echo "$RESPONSE" | jq -r '.errors[].message' >&2
    exit 1
  fi
}

# ── Fetch account ID ──────────────────────────────────────────────────────────
echo "→ Fetching Cloudflare account..."
ACCOUNTS=$(cf GET "$CF_API/accounts")
check_success "$ACCOUNTS" "Account fetch"
ACCOUNT_ID=$(echo "$ACCOUNTS" | jq -r '.result[0].id')
ACCOUNT_NAME=$(echo "$ACCOUNTS" | jq -r '.result[0].name')
echo "  Account: $ACCOUNT_NAME ($ACCOUNT_ID)"

# ── Resolve tunnel (create if needed, verify if existing) ─────────────────────
TUNNEL_ID=""
TUNNEL_SECRET=""

if [ -f "$CREDS_FILE" ]; then
  TUNNEL_ID=$(jq -r '.TunnelID' "$CREDS_FILE")
  TUNNEL_SECRET=$(jq -r '.TunnelSecret' "$CREDS_FILE")
  echo "→ Existing tunnel found: $TUNNEL_ID"

  TUNNEL_INFO=$(cf GET "$CF_API/accounts/$ACCOUNT_ID/tunnels/$TUNNEL_ID")
  DELETED_AT=$(echo "$TUNNEL_INFO" | jq -r '.result.deleted_at')

  if [ "$DELETED_AT" != "null" ] && [ -n "$DELETED_AT" ]; then
    echo "  Tunnel was deleted from Cloudflare. Recreating..."
    TUNNEL_ID=""
    TUNNEL_SECRET=""
    rm -f "$CREDS_FILE"
  else
    TUNNEL_NAME_LIVE=$(echo "$TUNNEL_INFO" | jq -r '.result.name')
    echo "  Tunnel active: $TUNNEL_NAME_LIVE"
  fi
fi

if [ -z "$TUNNEL_ID" ]; then
  echo "→ Creating locally-managed tunnel: $TUNNEL_NAME"
  TUNNEL_SECRET=$(openssl rand -base64 32)

  RESPONSE=$(cf POST "$CF_API/accounts/$ACCOUNT_ID/tunnels" \
    --data-raw "$(jq -n \
      --arg name "$TUNNEL_NAME" \
      --arg secret "$TUNNEL_SECRET" \
      '{"name":$name,"tunnel_secret":$secret,"config_src":"local"}')")

  check_success "$RESPONSE" "Tunnel creation"
  TUNNEL_ID=$(echo "$RESPONSE" | jq -r '.result.id')
  echo "  Created: $TUNNEL_ID"

  jq -n \
    --arg account "$ACCOUNT_ID" \
    --arg secret "$TUNNEL_SECRET" \
    --arg tunnel "$TUNNEL_ID" \
    '{"AccountTag":$account,"TunnelSecret":$secret,"TunnelID":$tunnel}' \
    > "$CREDS_FILE"

  echo "  Credentials saved."
fi

TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"

# ── Configure DNS wildcard records ────────────────────────────────────────────
echo "→ Configuring DNS records → $TUNNEL_CNAME"

i=1
while true; do
  eval "domain=\$DOMAINNAME_$i"
  [ -z "$domain" ] && break

  ZONE_RESPONSE=$(cf GET "$CF_API/zones?name=$domain")
  ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id // empty')

  if [ -z "$ZONE_ID" ]; then
    echo "  WARNING: Zone not found for '$domain' — check CF token has DNS access" >&2
    i=$((i + 1))
    continue
  fi

  for record_name in "*.$domain" "$domain"; do
    ENCODED=$(printf '%s' "$record_name" | sed 's/\*/%2A/g')
    EXISTING=$(cf GET "$CF_API/zones/$ZONE_ID/dns_records?name=$ENCODED&type=CNAME")
    EXISTING_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')

    PAYLOAD=$(jq -n \
      --arg name "$record_name" \
      --arg content "$TUNNEL_CNAME" \
      '{"type":"CNAME","name":$name,"content":$content,"proxied":true}')

    if [ -n "$EXISTING_ID" ]; then
      CURRENT=$(echo "$EXISTING" | jq -r '.result[0].content')
      if [ "$CURRENT" = "$TUNNEL_CNAME" ]; then
        echo "  OK (unchanged): $record_name"
      else
        cf PUT "$CF_API/zones/$ZONE_ID/dns_records/$EXISTING_ID" \
          --data-raw "$PAYLOAD" > /dev/null
        echo "  Updated: $record_name"
      fi
    else
      cf POST "$CF_API/zones/$ZONE_ID/dns_records" \
        --data-raw "$PAYLOAD" > /dev/null
      echo "  Created: $record_name"
    fi
  done

  i=$((i + 1))
done

# ── Generate cloudflared config.yml ───────────────────────────────────────────
echo "→ Writing ingress config..."
printf 'tunnel: %s\ncredentials-file: %s\n\ningress:\n' \
  "$TUNNEL_ID" "$CREDS_FILE" > "$CONFIG_FILE"

i=1
while true; do
  eval "domain=\$DOMAINNAME_$i"
  [ -z "$domain" ] && break
  printf '  - hostname: "*.%s"\n    service: https://localhost:443\n    originRequest:\n      noTLSVerify: true\n' \
    "$domain" >> "$CONFIG_FILE"
  printf '  - hostname: "%s"\n    service: https://localhost:443\n    originRequest:\n      noTLSVerify: true\n' \
    "$domain" >> "$CONFIG_FILE"
  i=$((i + 1))
done
printf '  - service: http_status:404\n' >> "$CONFIG_FILE"

DOMAIN_COUNT=$((i - 1))
echo "→ Done. Tunnel $TUNNEL_ID configured for $DOMAIN_COUNT domain(s):"
grep 'hostname:.*\*\.' "$CONFIG_FILE" | sed 's/.*"\(.*\)"/  \1/'
