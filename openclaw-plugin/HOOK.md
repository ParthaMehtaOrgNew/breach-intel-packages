---
name: breach-intel
description: "Intercepts every outbound LLM message and tool call via OpenClaw and classifies it for compliance breaches in real-time. Supports fintech, healthcare, and pharma verticals."
metadata:
  {
    "openclaw":
      {
        "emoji": "🔒",
        "events": ["message:sent"],
        "requires":
          {
            "env": ["BREACH_INTEL_URL", "BREACH_INTEL_TOKEN", "BREACH_INTEL_AGENT_ID"],
          },
      },
  }
---

# Breach Intel Hook

Passively intercepts every outbound LLM message sent through the OpenClaw gateway and emits it to the Breach Intel Policy Agent for real-time compliance classification.

No code changes needed. Install once, every agent session is monitored.

## What It Does

1. Listens for `message:sent` events (every LLM response leaving the gateway)
2. Posts the content to the Breach Intel Policy Agent (`POST /events`)
3. Logs the breach classification result silently — never blocks or modifies messages

## Configuration

Set these environment variables (written automatically by `./install.sh`):

| Variable | Description |
|----------|-------------|
| `BREACH_INTEL_URL` | Policy agent URL (e.g. `http://localhost:8080`) |
| `BREACH_INTEL_TOKEN` | Agent-scoped API key |
| `BREACH_INTEL_AGENT_ID` | Stable agent identity for this machine |

Optional:
| Variable | Default | Description |
|----------|---------|-------------|
| `BREACH_INTEL_VERTICAL` | `fintech` | Compliance vertical: `fintech`, `healthcare`, `pharma` |
