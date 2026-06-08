#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# One-time setup for the local multi-worktree dev environment
# =============================================================================
#
# Run this once on a new machine to configure:
#   1. Homebrew dependencies (tmux, dnsmasq)
#   2. Wildcard DNS (*.local.lupapets.com → 127.0.0.1)
#   3. Docker proxy network
#   4. Traefik reverse proxy
#
# Usage: ./dev-setup.sh
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

LUPA_REPO="$HOME/workspace/lupa"

step() {
  echo ""
  echo -e "${BOLD}→ $1${RESET}"
}

ok() {
  echo -e "  ${GREEN}✓${RESET} $1"
}

skip() {
  echo -e "  ${DIM}· $1 (already done)${RESET}"
}

warn() {
  echo -e "  ${YELLOW}! $1${RESET}"
}

fail() {
  echo -e "  ${RED}✕ $1${RESET}"
}

echo ""
echo -e "${BOLD}Local dev environment setup${RESET}"
echo -e "${DIM}This configures wildcard DNS, Docker networks, and the Traefik proxy.${RESET}"

# ---- Homebrew deps ----
step "Checking Homebrew dependencies"

for pkg in tmux dnsmasq; do
  if brew list "$pkg" &>/dev/null; then
    skip "$pkg installed"
  else
    brew install "$pkg"
    ok "$pkg installed"
  fi
done

# ---- dnsmasq wildcard DNS ----
step "Configuring wildcard DNS (*.local.lupapets.com → 127.0.0.1)"

DNSMASQ_CONF="$(brew --prefix)/etc/dnsmasq.conf"
DNSMASQ_ENTRY="address=/local.lupapets.com/127.0.0.1"

if grep -qF "$DNSMASQ_ENTRY" "$DNSMASQ_CONF" 2>/dev/null; then
  skip "dnsmasq rule already in $DNSMASQ_CONF"
else
  echo "" >> "$DNSMASQ_CONF"
  echo "# Lupa local dev: route all *.local.lupapets.com to localhost" >> "$DNSMASQ_CONF"
  echo "$DNSMASQ_ENTRY" >> "$DNSMASQ_CONF"
  ok "Added wildcard rule to $DNSMASQ_CONF"
fi

# Restart dnsmasq
sudo brew services restart dnsmasq &>/dev/null
ok "dnsmasq restarted"

# ---- macOS resolver ----
step "Configuring macOS DNS resolver"

RESOLVER_DIR="/etc/resolver"
RESOLVER_FILE="$RESOLVER_DIR/local.lupapets.com"

if [ -f "$RESOLVER_FILE" ] && grep -qF "nameserver 127.0.0.1" "$RESOLVER_FILE" 2>/dev/null; then
  skip "Resolver already configured at $RESOLVER_FILE"
else
  sudo mkdir -p "$RESOLVER_DIR"
  echo "nameserver 127.0.0.1" | sudo tee "$RESOLVER_FILE" > /dev/null
  ok "Created $RESOLVER_FILE"
fi

# ---- Verify DNS ----
step "Verifying DNS resolution"

# Give dnsmasq a moment to restart
sleep 1

if dig +short test.local.lupapets.com @127.0.0.1 2>/dev/null | grep -q "127.0.0.1"; then
  ok "test.local.lupapets.com resolves to 127.0.0.1"
else
  warn "DNS not resolving yet — may take a few seconds or require a flush:"
  warn "  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
fi

# ---- Docker ----
step "Checking Docker"

if ! command -v docker &>/dev/null; then
  fail "Docker not found — install Docker Desktop first"
  exit 1
fi

if ! docker info &>/dev/null; then
  fail "Docker daemon not running — start Docker Desktop first"
  exit 1
fi

ok "Docker is running"

# ---- Docker networks ----
step "Checking Docker networks"

# Remove manually-created lupa_proxy if it has incorrect labels (Compose needs to own it)
if docker network inspect lupa_proxy &>/dev/null; then
  LABEL="$(docker network inspect lupa_proxy --format '{{index .Labels "com.docker.compose.network"}}' 2>/dev/null)"
  if [ "$LABEL" != "lupa_proxy" ]; then
    warn "lupa_proxy has incorrect labels — removing so Compose can recreate it"
    docker network rm lupa_proxy 2>/dev/null || true
  fi
fi

if docker network inspect supabase_network_lupa &>/dev/null; then
  skip "supabase_network_lupa network exists"
else
  warn "supabase_network_lupa not found — run 'supabase start' from $LUPA_REPO/supabase first"
fi

# ---- Traefik proxy (also creates lupa_proxy network with correct labels) ----
step "Starting Traefik reverse proxy"

if docker compose -f "$LUPA_REPO/docker-compose.proxy.yml" ps --status running -q 2>/dev/null | grep -q .; then
  skip "Traefik already running"
else
  docker compose -f "$LUPA_REPO/docker-compose.proxy.yml" up -d
  ok "Traefik started (lupa_proxy network created)"
fi

# ---- Summary ----
echo ""
echo -e "${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo -e "${DIM}Usage:${RESET}"
echo "  ./dev.sh my-feature                               # tmux + docker (default)"
echo "  ./dev.sh --no-docker my-feature                   # tmux, skip docker"
echo "  ./dev.sh --services server,work my-feature        # docker service set"
echo ""
echo -e "${DIM}URLs (with --docker):${RESET}"
echo "  http://work.<branch>.local.lupapets.com"
echo "  http://server.<branch>.local.lupapets.com"
echo "  http://localhost:8080                              # Traefik dashboard"
echo ""
echo -e "${DIM}Traefik dashboard: http://localhost:8080${RESET}"
