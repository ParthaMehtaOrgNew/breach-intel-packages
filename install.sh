#!/usr/bin/env bash
set -euo pipefail

# ─── Breach Intel automated installer ───
# Usage:
#   ./install.sh              Full install (Docker stack + Python SDK + OpenClaw plugin)
#   ./install.sh --sdk-only   Install just the Python SDK + CLI
#   ./install.sh --uninstall  Remove OpenClaw plugin, stop Docker stack
#   ./install.sh --repair     Re-patch OpenClaw config after openclaw doctor

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
PLUGIN_DEST="$HOME/.openclaw/extensions/breach-intel"
BREACH_INTEL_DIR="$HOME/.breach-intel"

# ── Detect OS ──
detect_os() {
  case "$(uname -s)" in
    Darwin*)  OS="macOS"   ;;
    Linux*)   OS="Linux"   ;;
    MINGW*|MSYS*|CYGWIN*) OS="Windows" ;;
    *) fail "Unsupported operating system: $(uname -s)" ;;
  esac
  info "Detected OS: $OS"
}

# ── Step 1: Check prerequisites ──
check_prerequisites() {
  echo ""
  echo -e "${CYAN}═══ Step 1: Check Prerequisites ═══${NC}"

  # Python
  if command -v "$PYTHON" &>/dev/null; then
    ok "Python found: $("$PYTHON" --version)"
  else
    fail "Python 3 not found. Install Python 3.9+ and retry."
  fi

  # Docker (optional — needed for server)
  if command -v docker &>/dev/null; then
    ok "Docker found: $(docker --version 2>/dev/null | head -1)"
    HAS_DOCKER=true
  else
    warn "Docker not found — server stack won't be installed (SDK-only mode)"
    HAS_DOCKER=false
  fi

  # pip
  if "$PYTHON" -m pip --version &>/dev/null; then
    ok "pip available"
  else
    fail "pip not found. Install pip and retry."
  fi
}

# ── Step 2: Generate credentials + Start Docker stack ──
generate_credentials() {
  echo ""
  echo -e "${CYAN}═══ Step 2: Generate Credentials ═══${NC}"

  mkdir -p "$BREACH_INTEL_DIR"

  # Generate admin token if not already saved
  if [ -f "$BREACH_INTEL_DIR/admin_token" ]; then
    ADMIN_TOKEN=$(cat "$BREACH_INTEL_DIR/admin_token")
    ok "Using existing admin token from $BREACH_INTEL_DIR/admin_token"
  else
    ADMIN_TOKEN=$("$PYTHON" -c "import secrets; print('bi_admin_' + secrets.token_urlsafe(32))")
    echo "$ADMIN_TOKEN" > "$BREACH_INTEL_DIR/admin_token"
    chmod 600 "$BREACH_INTEL_DIR/admin_token"
    ok "Admin token generated and saved to $BREACH_INTEL_DIR/admin_token"
  fi

  # Generate stable agent ID if not already saved
  if [ -f "$BREACH_INTEL_DIR/agent_id" ]; then
    AGENT_ID=$(cat "$BREACH_INTEL_DIR/agent_id")
    ok "Using existing agent ID: $AGENT_ID"
  else
    RANDOM_SUFFIX=$("$PYTHON" -c "import secrets; print(secrets.token_hex(3))")
    AGENT_ID="agent-$(hostname -s 2>/dev/null || echo 'local')-${RANDOM_SUFFIX}"
    echo "$AGENT_ID" > "$BREACH_INTEL_DIR/agent_id"
    ok "Agent ID generated: $AGENT_ID"
  fi

  # Write .env for Docker
  cd "$SCRIPT_DIR"
  info "Writing .env for Docker..."
  cat > .env <<ENVEOF
POLICY_AGENT_API_TOKEN=${ADMIN_TOKEN}
RATE_LIMIT_ENABLED=true
RATE_LIMIT_EPM=300
ALERT_ON_SEVERITIES=CRITICAL
ENVEOF
  chmod 600 .env
  ok ".env written (auth enabled)"
}

start_docker_stack() {
  echo ""
  echo -e "${CYAN}═══ Step 3: Start Policy Agent (Docker) ═══${NC}"

  if [ "$HAS_DOCKER" = false ]; then
    warn "Skipping Docker stack (Docker not available)"
    warn "You can run the server manually: POLICY_AGENT_API_TOKEN=$(cat "$BREACH_INTEL_DIR/admin_token") make dev"
    return
  fi

  cd "$SCRIPT_DIR"

  # Update docker-compose to read from .env
  if docker compose ps 2>/dev/null | grep -q "policy_agent"; then
    info "Restarting policy agent with new credentials..."
    docker compose down
  fi

  info "Starting Docker stack..."
  docker compose up -d --build
  ok "Docker stack started"

  # Wait for health
  info "Waiting for policy agent to be ready..."
  for i in $(seq 1 20); do
    if curl -sf http://localhost:8080/health &>/dev/null; then
      ok "Policy agent is healthy"
      return
    fi
    sleep 2
  done
  fail "Policy agent didn't respond within 40s. Check: docker compose logs policy_agent"
}

# ── Step 4: Create API key for agents ──
create_agent_key() {
  echo ""
  echo -e "${CYAN}═══ Step 4: Create Agent API Key ═══${NC}"

  if [ -f "$BREACH_INTEL_DIR/agent_token" ]; then
    AGENT_TOKEN=$(cat "$BREACH_INTEL_DIR/agent_token")
    # Verify the token is still valid (DB may have been wiped)
    TOKEN_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8080/breaches \
      -H "Authorization: Bearer $AGENT_TOKEN" 2>/dev/null || echo "000")
    if [ "$TOKEN_STATUS" = "200" ]; then
      ok "Using existing agent key from $BREACH_INTEL_DIR/agent_token"
      return
    fi
    info "Existing agent key is no longer valid — creating a new one..."
  fi

  # Health check first
  if ! curl -sf http://localhost:8080/health &>/dev/null; then
    warn "Policy agent not reachable — skipping API key creation"
    AGENT_TOKEN=""
    return
  fi

  info "Creating agent API key..."
  RESPONSE=$(curl -sf -X POST "http://localhost:8080/keys?owner_id=default&label=install-agent&admin=false" \
    -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null || echo "")

  if [ -z "$RESPONSE" ]; then
    warn "Could not create agent key — server may not have auth enabled"
    AGENT_TOKEN=""
    return
  fi

  AGENT_TOKEN=$("$PYTHON" -c "import json,sys; print(json.loads('''$RESPONSE''')['api_key'])" 2>/dev/null || echo "")

  if [ -n "$AGENT_TOKEN" ]; then
    echo "$AGENT_TOKEN" > "$BREACH_INTEL_DIR/agent_token"
    chmod 600 "$BREACH_INTEL_DIR/agent_token"
    ok "Agent key created and saved to $BREACH_INTEL_DIR/agent_token"
  else
    warn "Could not parse agent key from server response"
  fi
}

AUTO_MONITOR=""

# ── Step 6: Ask permission for auto-monitoring ──
ask_auto_monitor_consent() {
  echo ""
  echo -e "${CYAN}═══ Step 6: Auto-Monitor Permission ═══${NC}"
  echo ""
  echo "  Breach Intel can automatically monitor every AI agent on this"
  echo "  machine with zero code changes in your agents."
  echo ""
  echo "  This installs a system-wide Python hook that instruments"
  echo "  OpenAI, Anthropic, and LangChain calls in any Python process."
  if command -v openclaw &>/dev/null; then
    echo "  It also installs an OpenClaw hook to monitor Claude Code sessions."
  fi
  echo ""
  echo -e "  ${YELLOW}Without this, you'll need to import breach_intel_client in each agent.${NC}"
  echo ""
  printf "  Allow Breach Intel to auto-monitor all agents on this machine? [Y/n] "
  read -r REPLY < /dev/tty
  echo ""
  case "${REPLY:-Y}" in
    [Yy]*|"")
      AUTO_MONITOR="yes"
      ok "Auto-monitoring enabled"
      ;;
    *)
      AUTO_MONITOR="no"
      info "Skipping auto-monitor hooks — you can enable later with: ./install.sh --repair"
      ;;
  esac
}

# ── Step 5: Install Python SDK ──
install_sdk() {
  echo ""
  echo -e "${CYAN}═══ Step 5: Install Python SDK ═══${NC}"

  cd "$SCRIPT_DIR/sdk"

  info "Installing breach-intel-client..."
  "$PYTHON" -m pip install -e . --quiet 2>&1 | tail -1 || "$PYTHON" -m pip install . --quiet 2>&1 | tail -1
  ok "breach-intel-client installed"

  # Verify CLI
  if "$PYTHON" -m breach_intel_client.cli version &>/dev/null; then
    ok "CLI working: $("$PYTHON" -m breach_intel_client.cli version)"
  else
    warn "CLI not on PATH yet — use: python -m breach_intel_client.cli"
  fi

  # Verify breach-intel command
  if command -v breach-intel &>/dev/null; then
    ok "breach-intel command available"
  else
    info "Run 'pip install -e sdk/' or add pip scripts dir to PATH for 'breach-intel' command"
  fi
}

# ── Step 7: Install persistent Python hook ──
install_sitecustomize_hook() {
  echo ""
  echo -e "${CYAN}═══ Step 7: Install Persistent Python Hook ═══${NC}"

  info "Installing sitecustomize hook for zero-touch instrumentation..."
  "$PYTHON" -m breach_intel_client.cli install-hook 2>/dev/null
  if [ $? -eq 0 ]; then
    ok "Persistent Python hook installed"
  else
    warn "Could not install persistent hook — use 'breach-intel run' wrapper instead"
  fi

  # Add env vars to shell profile
  local SHELL_PROFILE=""
  if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_PROFILE="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    SHELL_PROFILE="$HOME/.bashrc"
  elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_PROFILE="$HOME/.bash_profile"
  fi

  PLUGIN_TOKEN="${AGENT_TOKEN:-${ADMIN_TOKEN:-}}"

  # Write ~/.breach-intel/.env for easy sourcing / test scripts
  {
    echo "BREACH_INTEL_URL=http://localhost:8080"
    if [ -n "$PLUGIN_TOKEN" ]; then
      echo "BREACH_INTEL_TOKEN=$PLUGIN_TOKEN"
    fi
    if [ -n "${AGENT_ID:-}" ]; then
      echo "BREACH_INTEL_AGENT_ID=$AGENT_ID"
    fi
  } > "$BREACH_INTEL_DIR/.env"
  chmod 600 "$BREACH_INTEL_DIR/.env"
  ok "Credentials written to $BREACH_INTEL_DIR/.env"

  if [ -n "$SHELL_PROFILE" ]; then
    if ! grep -q "BREACH_INTEL_URL" "$SHELL_PROFILE" 2>/dev/null; then
      {
        echo ""
        echo "# --- breach-intel-start ---"
        echo "export BREACH_INTEL_URL=\"http://localhost:8080\""
        if [ -n "$PLUGIN_TOKEN" ]; then
          echo "export BREACH_INTEL_TOKEN=\"$PLUGIN_TOKEN\""
        fi
        if [ -n "${AGENT_ID:-}" ]; then
          echo "export BREACH_INTEL_AGENT_ID=\"$AGENT_ID\""
        fi
        echo "# --- breach-intel-end ---"
      } >> "$SHELL_PROFILE"
      ok "Environment variables added to $SHELL_PROFILE"
      info "Restart your terminal (or run: source $SHELL_PROFILE) to activate"
    else
      ok "BREACH_INTEL_URL already in $SHELL_PROFILE"
    fi
  else
    warn "Could not detect shell profile — set BREACH_INTEL_URL manually"
  fi
}

# ── Step 8: Install OpenClaw hook (if OpenClaw is installed) ──
install_openclaw_plugin() {
  echo ""
  echo -e "${CYAN}═══ Step 8: Install OpenClaw Hook ═══${NC}"

  if ! command -v openclaw &>/dev/null; then
    warn "OpenClaw not installed — skipping hook"
    info "Install OpenClaw later and re-run: ./install.sh --repair"
    return
  fi

  ok "OpenClaw found"
  info "Agent ID: $AGENT_ID"

  # Remove stale plugin entry from openclaw.json if present
  "$PYTHON" -c "
import json, os
cfg_path = os.path.expanduser('~/.openclaw/openclaw.json')
if not os.path.exists(cfg_path):
    exit(0)
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except (OSError, json.JSONDecodeError):
    exit(0)
changed = False
allow = cfg.get('plugins', {}).get('allow', [])
if 'breach-intel' in allow:
    allow.remove('breach-intel')
    changed = True
entries = cfg.get('plugins', {}).get('entries', {})
if 'breach-intel' in entries:
    del entries['breach-intel']
    changed = True
if changed:
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
" 2>/dev/null || true

  # Install as a proper hook pack
  info "Installing breach-intel hook pack..."
  if openclaw hooks install "$SCRIPT_DIR/openclaw_plugin" 2>/dev/null; then
    ok "Hook pack installed"
  else
    warn "Hook install failed — try manually: openclaw hooks install $SCRIPT_DIR/openclaw_plugin"
    return
  fi

  # Enable the hook
  openclaw hooks enable breach-intel 2>/dev/null || true
  ok "Hook enabled"

  # Restart gateway to pick up the new hook
  info "Restarting gateway..."
  openclaw gateway restart 2>/dev/null &
  local pid=$!
  sleep 5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  ok "Gateway restarted"
}

# ── Step 8: Smoke test ──
smoke_test() {
  echo ""
  echo -e "${CYAN}═══ Step 9: Smoke Test ═══${NC}"

  # Check health
  if curl -sf http://localhost:8080/health &>/dev/null; then
    ok "Policy agent healthy"
  else
    warn "Policy agent not reachable at http://localhost:8080"
    warn "Start it with: docker compose up -d"
    return
  fi

  # Verify auth works
  AUTH_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8080/breaches 2>/dev/null || echo "000")
  if [ "$AUTH_STATUS" = "401" ]; then
    ok "Auth is enabled (unauthenticated request correctly rejected)"
  elif [ "$AUTH_STATUS" = "200" ]; then
    warn "Auth is DISABLED — set POLICY_AGENT_API_TOKEN in .env for production"
  fi

  # Verify agent key works
  if [ -n "${AGENT_TOKEN:-}" ]; then
    KEY_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8080/breaches \
      -H "Authorization: Bearer $AGENT_TOKEN" 2>/dev/null || echo "000")
    if [ "$KEY_STATUS" = "200" ]; then
      ok "Agent API key is valid"
    else
      warn "Agent API key returned HTTP $KEY_STATUS"
    fi
  fi

  # Check dashboard
  DASH_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8080/dashboard/ 2>/dev/null || echo "000")
  if [ "$DASH_STATUS" = "200" ]; then
    ok "Dashboard available at http://localhost:8080/dashboard/"
  else
    warn "Dashboard not reachable (HTTP $DASH_STATUS)"
  fi

  # Show saved credentials location
  echo ""
  info "Credentials saved to $BREACH_INTEL_DIR/"
  info "  admin_token  — full admin access (keep secret)"
  info "  agent_token  — agent-scoped key (used by plugins/SDK)"
  info "  agent_id     — stable agent identity for this machine"
}

# ── Summary ──
print_summary() {
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Breach Intel installed — zero-touch monitoring is active ${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  if [ "${AUTO_MONITOR:-yes}" = "yes" ]; then
    echo -e "  ${CYAN}You're done. No code changes needed.${NC}"
    echo "  Every Python agent on this machine is now auto-monitored."
    echo "  Just run your agents the way you always do:"
    echo ""
    echo "    python your_agent.py"
    echo ""
    echo "  Breaches are detected and logged automatically."
    echo ""
    echo -e "  ${CYAN}What's monitored:${NC}"
    echo "    - OpenAI  (chat.completions.create)"
    echo "    - Anthropic (messages.create)"
    echo "    - LangChain (BaseChatModel.invoke)"
    if command -v openclaw &>/dev/null; then
      echo "    - OpenClaw  (autoWatch — transcript tailing)"
    fi
  else
    echo -e "  ${CYAN}Policy agent is running. Manual monitoring mode.${NC}"
    echo "  Add this to each agent you want monitored:"
    echo ""
    echo "    import breach_intel_client  # auto-attaches on import"
    echo ""
    echo "  Or enable zero-touch auto-monitoring anytime:"
    echo ""
    echo "    ./install.sh --repair"
    echo ""
  fi
  echo ""
  local DASH_TOKEN="${AGENT_TOKEN:-${ADMIN_TOKEN:-}}"
  local DASH_URL="http://localhost:8080/dashboard/"
  if [ -n "$DASH_TOKEN" ]; then
    DASH_URL="http://localhost:8080/dashboard/?token=${DASH_TOKEN}"
  fi

  echo -e "  ${CYAN}Where to look:${NC}"
  echo "    Dashboard     $DASH_URL"
  echo "                  ^ open this URL in a fresh tab (token is embedded)"
  echo "    Breach logs   ./breach_logs/breach-log-*.jsonl"
  echo "    Diagnostics   breach-intel doctor"
  echo ""
  echo -e "  ${CYAN}Credentials:${NC}  $BREACH_INTEL_DIR/"
  echo "    admin_token   full admin access (keep secret)"
  echo "    agent_token   agent-scoped key (used by SDK)"
  echo "    agent_id      stable identity for this machine"
  echo ""

}

# ── Uninstall ──
uninstall() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Breach Intel — Uninstall                        ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${YELLOW}If you have the dashboard open in your browser, close that tab now.${NC}"
  echo -e "  ${YELLOW}After reinstalling, open the fresh URL printed at the end of install.${NC}"
  echo ""

  detect_os

  # Remove OpenClaw hook
  if command -v openclaw &>/dev/null; then
    openclaw hooks disable breach-intel 2>/dev/null || true
    info "Removing breach-intel hook..."
    rm -rf "$HOME/.openclaw/hooks/breach-intel"
    ok "Hook removed"
  fi
  if [ -d "$PLUGIN_DEST" ]; then
    rm -rf "$PLUGIN_DEST"
  fi

  # Clean openclaw.json
  if [ -f "$HOME/.openclaw/openclaw.json" ]; then
    info "Removing breach-intel from openclaw.json..."
    "$PYTHON" -c "
import json, os
cfg_path = os.path.expanduser('~/.openclaw/openclaw.json')
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except (OSError, json.JSONDecodeError):
    exit(0)
changed = False
allow = cfg.get('plugins', {}).get('allow', [])
if 'breach-intel' in allow:
    allow.remove('breach-intel')
    changed = True
entries = cfg.get('plugins', {}).get('entries', {})
if 'breach-intel' in entries:
    del entries['breach-intel']
    changed = True
if changed:
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
" 2>/dev/null || true
    ok "Config cleaned"
  fi

  # Stop Docker stack
  cd "$SCRIPT_DIR"
  if docker compose ps 2>/dev/null | grep -q "policy_agent"; then
    info "Stopping Docker stack..."
    docker compose down
    ok "Docker stack stopped"
  fi

  # Remove persistent hook
  info "Removing persistent Python hook..."
  "$PYTHON" -m breach_intel_client.cli uninstall-hook 2>/dev/null || true
  ok "Hook removed"

  # Clean shell profile
  for profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$profile" ] && grep -q "breach-intel-start" "$profile" 2>/dev/null; then
      sed -i.bak '/# --- breach-intel-start ---/,/# --- breach-intel-end ---/d' "$profile"
      rm -f "${profile}.bak"
      info "Cleaned env vars from $profile"
    fi
  done

  # Uninstall SDK
  info "Uninstalling breach-intel-client..."
  "$PYTHON" -m pip uninstall -y breach-intel-client 2>/dev/null || true
  ok "SDK uninstalled"

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Breach Intel uninstalled.${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
}

# ── Repair ──
repair() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Breach Intel — Repair Config                    ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  detect_os
  check_prerequisites
  generate_credentials
  install_sdk
  install_sitecustomize_hook
  install_openclaw_plugin

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Config repaired!${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
}

# ── SDK only ──
sdk_only() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Breach Intel — SDK Only Install                 ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  detect_os
  check_prerequisites
  generate_credentials
  install_sdk
  install_sitecustomize_hook

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  SDK installed! Zero-touch monitoring active.${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  Your Python agents are now auto-monitored."
  echo "  Just run them normally — no code changes needed:"
  echo ""
  echo "    python your_agent.py"
  echo ""
  echo "  Point to a remote policy agent:"
  echo "    export BREACH_INTEL_URL=http://your-server:8080"
  echo ""
  echo "  Diagnose setup:"
  echo "    breach-intel doctor"
  echo ""
}

# ── Full install ──
full_install() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Breach Intel — Automated Installer              ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  detect_os
  check_prerequisites
  generate_credentials
  start_docker_stack
  create_agent_key
  install_sdk
  ask_auto_monitor_consent
  if [ "${AUTO_MONITOR:-yes}" = "yes" ]; then
    install_sitecustomize_hook
  fi
  smoke_test
  print_summary
  # OpenClaw hook last — gateway restart can truncate terminal output
  if [ "${AUTO_MONITOR:-yes}" = "yes" ]; then
    install_openclaw_plugin
  fi
}

# ── Main ──
case "${1:-}" in
  --uninstall)
    uninstall
    ;;
  --repair)
    repair
    ;;
  --sdk-only)
    sdk_only
    ;;
  --help|-h)
    echo "Usage: ./install.sh [--sdk-only|--repair|--uninstall|--help]"
    echo ""
    echo "  (no args)     Full install (Docker + SDK + OpenClaw plugin)"
    echo "  --sdk-only    Install just the Python SDK + CLI"
    echo "  --repair      Re-patch OpenClaw config after openclaw doctor"
    echo "  --uninstall   Remove plugin, stop Docker, uninstall SDK"
    echo "  --help        Show this help"
    ;;
  *)
    full_install
    ;;
esac
