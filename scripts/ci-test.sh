#!/usr/bin/env bash
set -euo pipefail

scratch=$(mktemp -d)
pg_name="relay-ci-$(uv run python -c 'import uuid; print(uuid.uuid4().hex[:12])')"
api_pid=""
cleanup() {
  if [[ -n "$api_pid" ]]; then
    kill "$api_pid" 2>/dev/null || true
    wait "$api_pid" 2>/dev/null || true
  fi
  docker rm -f "$pg_name" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

docker run -d --name "$pg_name" \
  -e POSTGRES_USER=relay -e POSTGRES_PASSWORD=ci-only \
  -e POSTGRES_DB=protocol_test -p 127.0.0.1::5432 postgres:17 >/dev/null
for attempt in {1..60}; do
  if docker exec "$pg_name" pg_isready -U relay -d protocol_test >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$pg_name" pg_isready -U relay -d protocol_test
pg_port=$(docker port "$pg_name" 5432/tcp | head -1 | awk -F: '{print $NF}')
db_base="postgresql+psycopg://relay:ci-only@127.0.0.1:$pg_port"
docker exec "$pg_name" createdb -U relay live_test

# Destructive schema fixtures only touch the disposable protocol_test DB.
RELAY_DATABASE_URL="$db_base/protocol_test" uv run pytest -q test_agent_relay.py

api_port=$(uv run python -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
RELAY_DATABASE_URL="$db_base/live_test" uv run uvicorn main:app \
  --host 127.0.0.1 --port "$api_port" >"$scratch/api.log" 2>&1 &
api_pid=$!
export RELAY_TEST_BASE_URL="http://127.0.0.1:$api_port"
if ! uv run python - <<'PY'
import os, time, urllib.request
for _ in range(60):
    try:
        with urllib.request.urlopen(os.environ['RELAY_TEST_BASE_URL'] + '/ready', timeout=1) as r:
            if r.status == 200:
                break
    except OSError:
        time.sleep(.5)
else:
    raise SystemExit('CI API did not become ready')
PY
then
  cat "$scratch/api.log"
  exit 1
fi
uv run pytest -q test_live_api.py
