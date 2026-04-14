#!/bin/bash
# Breach Intel OpenClaw Plugin Installer
# Installs the breach-intel plugin into your local OpenClaw setup.
#
# Usage: bash install.sh [--policy-agent-url URL] [--agent-id ID] [--vertical VERTICAL]

set -e

POLICY_AGENT_URL="${BREACH_INTEL_URL:-http://localhost:8080}"
AGENT_ID="${BREACH_INTEL_AGENT_ID:-}"
VERTICAL="${BREACH_INTEL_VERTICAL:-fintech}"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --policy-agent-url) POLICY_AGENT_URL="$2"; shift 2 ;;
    --agent-id)         AGENT_ID="$2"; shift 2 ;;
    --vertical)         VERTICAL="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

PLUGIN_DIR="$HOME/.openclaw/extensions/breach-intel"

echo "Installing Breach Intel plugin..."
mkdir -p "$PLUGIN_DIR"

# Copy plugin files
cp "$(dirname "$0")/index.ts" "$PLUGIN_DIR/"
cp "$(dirname "$0")/openclaw.plugin.json" "$PLUGIN_DIR/"

# Patch openclaw.json
python3 - <<PYEOF
import json, os, sys

cfg_path = os.path.expanduser("~/.openclaw/openclaw.json")
if not os.path.exists(cfg_path):
    print(f"openclaw.json not found at {cfg_path}", file=sys.stderr)
    sys.exit(1)

with open(cfg_path) as f:
    cfg = json.load(f)

# Add plugin to allow list
cfg.setdefault("plugins", {}).setdefault("allow", [])
if "breach-intel" not in cfg["plugins"]["allow"]:
    cfg["plugins"]["allow"].append("breach-intel")

# Write plugin config
cfg.setdefault("pluginConfig", {})["breach-intel"] = {
    "policyAgentUrl": "${POLICY_AGENT_URL}",
    "agentId": "${AGENT_ID}",
    "vertical": "${VERTICAL}",
    "silent": True,
}

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("openclaw.json patched")
PYEOF

echo ""
echo "✅ Breach Intel plugin installed."
echo ""
echo "Config written to ~/.openclaw/openclaw.json:"
echo "  policyAgentUrl: $POLICY_AGENT_URL"
echo "  agentId:        ${AGENT_ID:-<not set — set BREACH_INTEL_AGENT_ID or register via API>}"
echo "  vertical:       $VERTICAL"
echo ""
echo "Restart the gateway to load the plugin:"
echo "  openclaw gateway restart"
echo ""
echo "Then verify:"
echo "  openclaw plugins list"
echo "  # Expected: breach-intel -> loaded"
