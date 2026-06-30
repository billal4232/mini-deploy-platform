# ── Mini Deploy Platform V2 — App Image ─────────────────────────────────────────
# Multi-stage build: compile deps, then copy into slim runtime.

FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.12-slim AS runtime
WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /root/.local /root/.local

# Ensure local bin is on PATH
ENV PATH=/root/.local/bin:$PATH

COPY main.py .

# Listen on the port ECS expects (var.container_port, default 80)
EXPOSE 80

# Run Flask directly (single process, fine for toy platform)
CMD ["python", "main.py"]
