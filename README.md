# Breach Intel — Distribution Packages

Pre-built packages and installers for **Breach Intel**, the audit layer for AI agents.

> Policy agent infrastructure that attaches to any AI agent and produces tamper-evident breach audit logs — automatically. Zero code changes.

## Quick Install

```bash
# One-line install (recommended)
./install.sh

# SDK only (no Docker)
./install.sh --sdk-only

# Or install directly from PyPI
pip install breach-intel-client
```

## What's Included

### `install.sh`
Automated installer that handles everything:
- Detects OS (macOS / Linux / Windows)
- Checks prerequisites (Python 3.9+, Docker)
- Installs the Python SDK (`breach-intel-client`)
- Sets up the persistent auto-instrumentation hook
- Starts the Docker stack (policy agent + PostgreSQL)
- Registers your agent and prints the dashboard URL

### `sdk/`
Pre-built Python SDK packages (also available on [PyPI](https://pypi.org/project/breach-intel-client/)):

| File | Version | Description |
|------|---------|-------------|
| `breach_intel_client-0.3.1-py3-none-any.whl` | 0.3.1 | Latest wheel (recommended) |
| `breach_intel_client-0.3.1.tar.gz` | 0.3.1 | Latest source distribution |
| `breach_intel_client-0.1.0-py3-none-any.whl` | 0.1.0 | Legacy wheel |
| `breach_intel_client-0.1.0.tar.gz` | 0.1.0 | Legacy source distribution |

Install from local file:
```bash
pip install sdk/breach_intel_client-0.3.1-py3-none-any.whl
```

### `openclaw-plugin/`
OpenClaw integration plugin for real-time breach detection within the OpenClaw AI agent framework:

| File | Description |
|------|-------------|
| `index.ts` | Plugin entry point |
| `handler.ts` | Event handler (intercepts LLM messages) |
| `openclaw.plugin.json` | Plugin manifest |
| `install.sh` | Plugin-specific installer |
| `HOOK.md` | Integration documentation |

### `docker-compose.yml` + `Dockerfile`
Docker stack for running the policy agent server:
```bash
docker compose up --build
```
Starts:
- **Policy Agent** (FastAPI) on port 8080
- **PostgreSQL 16** for breach record storage
- **Dashboard** at `http://localhost:8080/dashboard/`

## Supported Platforms

| Platform | install.sh | SDK | OpenClaw Plugin | Docker |
|----------|-----------|-----|-----------------|--------|
| macOS    | ✓         | ✓   | ✓               | ✓      |
| Linux    | ✓         | ✓   | ✓               | ✓      |
| Windows  | ✓         | ✓   | ✓               | ✓      |

## Requirements

- Python 3.9+
- Docker (for full install, not needed for SDK-only)
- pip

## Verify Installation

```bash
breach-intel doctor
```

## Links

- **Website**: [parthamehtaorg.github.io/breach-intel-site](https://parthamehtaorg.github.io/breach-intel-site/)
- **PyPI**: [pypi.org/project/breach-intel-client](https://pypi.org/project/breach-intel-client/)
- **Documentation**: [Docs](https://parthamehtaorg.github.io/breach-intel-site/docs.html)

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
