#!/usr/bin/env bash
# install.sh — Deployrr stack integration for cloudflare-tunnel-auto
#
# Detects your Deployrr environment, reads existing .env and secrets,
# registers the app in your stack, and starts the tunnel.
#
# Usage:
#   bash install.sh
#
# For standalone (non-Deployrr) use, see README.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_SRC="$REPO_DIR/compose.yml"

DEPLOYRR_DIR="/opt/deployrr"
DOCKER_DIR="$HOME/docker"
DOCKER_ENV="$DOCKER_DIR/.env"
DOCKER_SECRETS_DIR="$DOCKER_DIR/secrets"
MASTER_COMPOSE="$DOCKER_DIR/docker-compose-plexy.yml"
DEPLOYRR_COMPOSE_DEST="$DOCKER_DIR/compose/plexy/cloudflare-tunnel-auto.yml"

SECRET_NAME="cf_dns_api_token"
INIT_SVC="cloudflare-tunnel-auto-init"
TUNNEL_SVC="cloudflare-tunnel-auto"
IMAGE_INIT="ghcr.io/onttm/cloudflare-tunnel-init:latest"
IMAGE_CLOUDFLARED="cloudflare/cloudflared:latest"

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GRN}✓${NC} $*"; }
info() { echo -e "  ${YLW}→${NC} $*"; }
die()  { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

# ── Ensure sudo credentials are cached ───────────────────────────────────────
ensure_sudo() {
    if sudo -n true 2>/dev/null; then
        return
    fi
    echo ""
    echo "  This installer needs sudo to read your stack's .env, write secrets,"
    echo "  and modify your Deployrr compose files."
    echo ""
    sudo -v || die "sudo authentication failed — cannot continue"
    ok "sudo credentials cached"
}

# ── Verify this is a Deployrr environment ────────────────────────────────────
verify_deployrr() {
    local ok=true
    [[ -d "$DEPLOYRR_DIR" ]]        || ok=false
    [[ -f "$MASTER_COMPOSE" ]]      || ok=false
    [[ -d "$DOCKER_SECRETS_DIR" ]]  || ok=false
    [[ -f "$DOCKER_ENV" ]]          || ok=false

    if ! $ok; then
        die "Deployrr environment not found. For standalone use, see README.md."
    fi

    if ! sudo grep -q "^DOMAINNAME_1=" "$DOCKER_ENV" 2>/dev/null; then
        die "DOMAINNAME_1 is not set in $DOCKER_ENV. Add it before running this script."
    fi

    ok "Deployrr environment detected"
}

# ── Warn if official cloudflare-tunnel app is present ────────────────────────
check_official_conflict() {
    local official_compose="$DOCKER_DIR/compose/plexy/cloudflare-tunnel.yml"
    local conflict=false

    sudo test -f "$official_compose" 2>/dev/null && conflict=true
    sudo grep -q "compose/plexy/cloudflare-tunnel.yml" "$MASTER_COMPOSE" 2>/dev/null && conflict=true

    if $conflict; then
        echo ""
        echo -e "  ${YLW}Warning: the official Deployrr cloudflare-tunnel app appears to be installed.${NC}"
        echo "  Running both simultaneously will split traffic unpredictably across two"
        echo "  competing tunnels pointing at the same domains. Remove it first:"
        echo "    docker compose -f $MASTER_COMPOSE down cloudflare-tunnel"
        echo "    sudo rm $official_compose"
        echo "  Then remove its include and secret entries from $MASTER_COMPOSE"
        echo ""
        read -rp "  Continue anyway? [y/N]: " choice || true
        [[ "$choice" =~ ^[yY]$ ]] || { echo "  Aborted."; exit 0; }
    fi
}

# ── Idempotency — offer update path if already installed ─────────────────────
check_idempotency() {
    if sudo test -f "$DEPLOYRR_COMPOSE_DEST" 2>/dev/null; then
        echo ""
        echo -e "  ${YLW}Existing installation detected at $DEPLOYRR_COMPOSE_DEST${NC}"
        read -rp "  Re-pull images and restart services? [y/N]: " choice || true
        case "$choice" in
            y|Y)
                pull_images
                sudo docker compose -f "$MASTER_COMPOSE" up -d --force-recreate \
                    "$INIT_SVC" "$TUNNEL_SVC"
                tail_init_logs
                print_success
                exit 0
                ;;
            *)
                echo "  Aborted."
                exit 0
                ;;
        esac
    fi
}

# ── Read env vars from root-owned .env (never source it) ─────────────────────
read_env() {
    for i in 1 2 3 4 5; do
        local val
        val=$(sudo grep "^DOMAINNAME_${i}=" "$DOCKER_ENV" 2>/dev/null \
              | cut -d= -f2- | tr -d "\"'" || true)
        [[ -n "$val" ]] && export "DOMAINNAME_${i}=$val"
    done

    local tunnel_name
    tunnel_name=$(sudo grep "^CLOUDFLARE_TUNNEL_NAME=" "$DOCKER_ENV" 2>/dev/null \
                  | cut -d= -f2- | tr -d "\"'" || true)
    export CLOUDFLARE_TUNNEL_NAME="${tunnel_name:-homelab}"

    ok "Read environment: DOMAINNAME_1=${DOMAINNAME_1}, CLOUDFLARE_TUNNEL_NAME=${CLOUDFLARE_TUNNEL_NAME}"
}

# ── Ensure the API token secret exists ───────────────────────────────────────
ensure_secret() {
    local secret_path="$DOCKER_SECRETS_DIR/$SECRET_NAME"

    if sudo test -f "$secret_path" 2>/dev/null; then
        ok "Secret $SECRET_NAME already exists — skipping"
        return
    fi

    info "Cloudflare Account API token not found"
    echo ""
    echo "    Create one at: dash.cloudflare.com → Account Home → Manage Account → API Tokens"
    echo "    Required permissions:"
    echo "      Zone → DNS → Edit"
    echo "      Account → Cloudflare One Connectors → Edit"
    echo ""
    local token
    read -rsp "  Paste token: " token || true
    echo ""
    [[ -n "$token" ]] || die "Token cannot be empty"

    # Write via heredoc — token travels through stdin, never appears in argv
    sudo bash -c "cat > \"$secret_path\"" <<< "$token"
    sudo chmod 600 "$secret_path"
    ok "Secret written to $secret_path"
}

# ── Copy compose file, uncomment Deployrr profiles ───────────────────────────
install_compose() {
    sudo cp "$COMPOSE_SRC" "$DEPLOYRR_COMPOSE_DEST"

    # Uncomment the profiles line for Deployrr stack integration
    sudo sed -i \
        's|^\s*#\s*profiles: \["core", "all"\].*|    profiles: ["core", "all"]|' \
        "$DEPLOYRR_COMPOSE_DEST"

    # Validate YAML is still well-formed after sed substitution
    docker compose -f "$DEPLOYRR_COMPOSE_DEST" config --quiet 2>/dev/null \
        || die "Compose file failed YAML validation after install — check $DEPLOYRR_COMPOSE_DEST"

    ok "Compose file installed to $DEPLOYRR_COMPOSE_DEST"
}

# ── Register include in master compose ───────────────────────────────────────
register_include() {
    local placeholder="SERVICE-PLACEHOLDER-DO-NOT-DELETE"
    local include_line="  - compose/plexy/cloudflare-tunnel-auto.yml"

    if sudo grep -q "cloudflare-tunnel-auto.yml" "$MASTER_COMPOSE" 2>/dev/null; then
        ok "Include already registered — skipping"
        return
    fi

    sudo awk -v line="$include_line" -v ph="$placeholder" '
        $0 ~ ph { print line }
        { print }
    ' "$MASTER_COMPOSE" | sudo tee "$MASTER_COMPOSE".tmp > /dev/null
    sudo mv "$MASTER_COMPOSE".tmp "$MASTER_COMPOSE"
    ok "Include registered in master compose"
}

# ── Register secret block in master compose ──────────────────────────────────
register_secret() {
    local placeholder="SECRETS-PLACEHOLDER-DO-NOT-DELETE"

    if sudo grep -q "cf_dns_api_token" "$MASTER_COMPOSE" 2>/dev/null; then
        ok "Secret block already registered — skipping"
        return
    fi

    local dockerdir
    dockerdir=$(sudo grep "^DOCKERDIR=" "$DOCKER_ENV" 2>/dev/null \
                | cut -d= -f2- | tr -d "\"'" || echo "$DOCKER_DIR")

    local block="  cf_dns_api_token:\n    file: ${dockerdir}/secrets/cf_dns_api_token"

    sudo awk -v block="$block" -v ph="$placeholder" '
        $0 ~ ph { printf "%s\n", block }
        { print }
    ' "$MASTER_COMPOSE" | sudo tee "$MASTER_COMPOSE".tmp > /dev/null
    sudo mv "$MASTER_COMPOSE".tmp "$MASTER_COMPOSE"
    ok "Secret block registered in master compose"
}

# ── Pull latest images ────────────────────────────────────────────────────────
pull_images() {
    info "Pulling latest images..."
    docker pull "$IMAGE_INIT"    2>&1 | grep -E "Pulling|Pull complete|up to date|Status" || true
    docker pull "$IMAGE_CLOUDFLARED" 2>&1 | grep -E "Pulling|Pull complete|up to date|Status" || true
}

# ── Launch services ───────────────────────────────────────────────────────────
launch() {
    sudo docker compose -f "$MASTER_COMPOSE" up -d "$INIT_SVC" "$TUNNEL_SVC" 2>&1
}

# ── Tail init container logs until it exits ──────────────────────────────────
tail_init_logs() {
    info "Waiting for init container..."
    local attempts=0
    until docker ps -a --format '{{.Names}}' | grep -q "^${INIT_SVC}$" || (( attempts++ > 15 )); do
        sleep 2
    done
    echo ""
    timeout 120 docker logs -f "$INIT_SVC" 2>&1 || true
    echo ""
}

# ── Success message ───────────────────────────────────────────────────────────
print_success() {
    echo -e "  ${GRN}${BLD}Cloudflare Tunnel Auto is running.${NC}"
    echo ""
    echo "  Verify:"
    echo "    docker logs $TUNNEL_SVC | grep Registered"
    echo ""
    echo "  To add a domain: add DOMAINNAME_N to $DOCKER_ENV, then:"
    echo "    docker compose -f $MASTER_COMPOSE up -d --force-recreate $INIT_SVC $TUNNEL_SVC"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLD}cloudflare-tunnel-auto — Deployrr installer${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    ensure_sudo
    verify_deployrr
    check_official_conflict
    check_idempotency
    read_env
    ensure_secret
    install_compose
    register_include
    register_secret
    pull_images
    launch
    tail_init_logs
    print_success
}

main "$@"
