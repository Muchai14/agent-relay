FROM ghcr.io/astral-sh/uv:0.12.17 AS uv
FROM python:3.11-slim

COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PYTHON_DOWNLOADS=never \
    PATH="/app/.venv/bin:$PATH" \
    RELAY_DATABASE_URL=sqlite:////data/agent-relay.db

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

RUN useradd --create-home relay && mkdir /data && chown relay:relay /data
COPY *.py dashboard.html ./
USER relay
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
