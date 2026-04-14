# Breach Intel — Distribution Packages

Pre-built packages and installers for **Breach Intel**, the audit layer for AI agents.

> Policy agent infrastructure that attaches to any AI agent and produces tamper-evident breach audit logs — automatically. Zero code changes.

## Overview

Breach Intel is a sidecar policy agent that intercepts every LLM response from your AI agents and classifies them for compliance breaches in **<1ms** — without touching your agent code.

**What gets detected:**
- **PII exposure** — SSN, Aadhaar, PAN, email, DOB patterns in agent responses
- **Card data** — Visa/MC/Amex numbers, CVV leaks
- **PHI exposure** — Protected health information, clinical notes, prescriptions
- **Cross-tenant leaks** — Agent mixing customer data across boundaries
- **Financial hallucinations** — Fabricated financial data or unauthorized advice
- **Trial data fabrication** — Fake clinical endpoints or subject records
- **40+ more** across Fintech, Healthcare, Pharma, and Sports verticals

## Package Contents

| File/Folder | Description |
|-------------|-------------|
| `install.sh` | Automated one-line installer (full / SDK-only / uninstall / repair) |
| `sdk/breach_intel_client-0.3.1-py3-none-any.whl` | Latest Python SDK wheel |
| `sdk/breach_intel_client-0.3.1.tar.gz` | Latest Python SDK source distribution |
| `sdk/breach_intel_client-0.1.0-py3-none-any.whl` | Legacy v0.1.0 wheel |
| `sdk/breach_intel_client-0.1.0.tar.gz` | Legacy v0.1.0 source distribution |
| `openclaw-plugin/index.ts` | OpenClaw plugin entry point |
| `openclaw-plugin/handler.ts` | Event handler (intercepts LLM messages) |
| `openclaw-plugin/openclaw.plugin.json` | Plugin manifest |
| `openclaw-plugin/install.sh` | Plugin-specific installer |
| `openclaw-plugin/HOOK.md` | Integration documentation |
| `docker-compose.yml` | Docker stack (policy agent + PostgreSQL) |
| `Dockerfile` | Multi-stage build for policy agent |

## Prerequisites

- Python 3.9+
- Docker (for full install; not needed for SDK-only)
- pip

## Installation

### Automated (Recommended)

```bash
./install.sh
```

What it does:
1. Detects OS (macOS / Linux / Windows)
2. Checks prerequisites (Python 3.9+, Docker)
3. Generates credentials (`~/.breach-intel/admin_token`, `agent_id`, `agent_token`)
4. Starts Docker stack (policy agent + PostgreSQL)
5. Installs Python SDK (`breach-intel-client`)
6. Installs persistent `sitecustomize.py` hook
7. Runs smoke test + prints dashboard URL

### SDK Only (No Docker)

```bash
./install.sh --sdk-only

# Or install directly from PyPI
pip install breach-intel-client
```

### Manual Setup

```bash
# 1. Start the server
docker compose up --build

# 2. Install the SDK
pip install sdk/breach_intel_client-0.3.1-py3-none-any.whl

# 3. Install the auto-instrumentation hook
breach-intel install-hook

# 4. Set environment variables
export BREACH_INTEL_URL=http://localhost:8080
export BREACH_INTEL_TOKEN=<your-api-key>
```

### OpenClaw Plugin

```bash
cd openclaw-plugin
./install.sh
```

## Verification

After installation, run diagnostics:

```bash
$ breach-intel doctor
✓ BREACH_INTEL_URL = http://localhost:8080
✓ Persistent hook installed
✓ Detected frameworks: OpenAI, Anthropic
✓ Server health: OK (v0.3.1)
✓ Credentials: valid
─────────────────────────────
All checks passed.
```

### Test Cases

**Should trigger a breach (PII_EXPOSURE):**
```python
# Run any agent that outputs SSN-like patterns
# e.g. "The customer's SSN is 123-45-6789"
# → Dashboard shows: PII_EXPOSURE, severity=CRITICAL
```

**Should pass clean:**
```python
# Normal agent responses without PII/PHI/card data
# → No breaches logged
```

### Open the Dashboard

```bash
open "http://localhost:8080/dashboard/?token=$(cat ~/.breach-intel/agent_token)"
```

## Supported Platforms

| Platform | install.sh | SDK | OpenClaw Plugin | Docker |
|----------|-----------|-----|-----------------|--------|
| macOS    | ✓         | ✓   | ✓               | ✓      |
| Linux    | ✓         | ✓   | ✓               | ✓      |
| Windows  | ✓         | ✓   | ✓               | ✓      |

## Architecture

```
Your AI Agent (OpenAI / Anthropic / LangChain / OpenClaw)
    │  (auto-patched at import time via sitecustomize.py)
    ▼
Policy Agent (FastAPI · :8080)
    ├─ Auth + Rate Limit (scoped API keys, 300/min)
    ├─ Classifier (rule-based, <1ms, deterministic)
    ├─ Breach Logger (DB + JSONL, SHA-256 chained)
    ├─ Webhook Alerter (Slack / Discord / generic)
    └─ Agentic Analyzer (LangGraph + Claude, async)
    │
    ▼
PostgreSQL/SQLite + breach_logs/*.jsonl + Webhook Endpoints
```

**Key guarantee:** The policy agent never blocks your AI agent. Events are processed with a 5-second timeout on the SDK side, failing silently on error.

## Uninstall

```bash
# Full uninstall (removes hook, stops Docker, cleans credentials)
./install.sh --uninstall

# Or manually
breach-intel uninstall-hook
docker compose down -v
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `breach-intel: command not found` | Run `pip install breach-intel-client` or check your PATH |
| Hook not intercepting agents | Verify `BREACH_INTEL_URL` is set: `echo $BREACH_INTEL_URL` |
| Dashboard shows no breaches | Run an agent that outputs PII patterns and check `breach-intel doctor` |
| Docker won't start | Ensure Docker daemon is running: `docker info` |
| Policy agent unreachable | Check port 8080: `curl http://localhost:8080/health` |
| Rate limit errors | Default is 300/min per key. Use admin key or increase `BREACH_INTEL_RATE_LIMIT` |

## Links

- **Website**: [parthamehtaorg.github.io/breach-intel-site](https://parthamehtaorg.github.io/breach-intel-site/)
- **PyPI**: [pypi.org/project/breach-intel-client](https://pypi.org/project/breach-intel-client/)
- **Documentation**: [Docs](https://parthamehtaorg.github.io/breach-intel-site/docs.html)
- **Pricing**: [Pricing](https://parthamehtaorg.github.io/breach-intel-site/pricing.html)

## Version

Current: **v0.3.1**

## Changelog

### v0.3.1
- Python 3.9 compatibility fix (`Optional[str]` instead of `str | None`)
- Auto-register agents with policy agent on attach
- Dashboard improvements

### v0.3.0
- Healthcare vertical (14 breach types, HIPAA taxonomy)
- Pharma vertical (14 breach types, FDA 21-CFR-11)
- Agentic deep analysis (LangGraph + Claude)

### v0.2.0
- OpenClaw plugin integration
- Webhook alerts (Slack, Discord, generic)
- Auto-scaling support

### v0.1.0
- Initial release
- Fintech vertical (12 breach types)
- SHA-256 hash chain
- Live dashboard
- Auto-instrumentation (OpenAI, Anthropic, LangChain)

## License

MIT
