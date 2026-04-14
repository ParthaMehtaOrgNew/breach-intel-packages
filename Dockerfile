# ── Stage 1: deps builder ─────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build deps
RUN pip install --no-cache-dir poetry==1.8.0 && \
    poetry config virtualenvs.create false

COPY pyproject.toml poetry.lock* ./
RUN poetry install --no-interaction --no-ansi --only main 2>/dev/null || \
    pip install --no-cache-dir \
        fastapi "uvicorn[standard]" pydantic pydantic-settings \
        sqlalchemy psycopg2-binary aiohttp

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

# Security: non-root user
RUN useradd -m -u 1001 agent

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin/uvicorn /usr/local/bin/uvicorn

# Copy source (owned by agent)
COPY --chown=agent:agent policy_agent/ ./policy_agent/
COPY --chown=agent:agent dashboard/ ./dashboard/

# Pre-create writable dirs for breach logs and archives
RUN mkdir -p /app/breach_logs /app/breach_archives && \
    chown agent:agent /app/breach_logs /app/breach_archives

# Switch to non-root
USER agent

EXPOSE 8080

# Liveness probe — fast, no DB
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

CMD ["uvicorn", "policy_agent.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--workers", "2", \
     "--no-access-log"]
