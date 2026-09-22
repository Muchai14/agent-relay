# Agent Relay (SQLite starter)

Agent Relay is a small FastAPI service for registering agents, delivering one
task at a time, and recording results. The local starter is self-contained:
SQLite persists the queue and attempts, while workers execute tasks on their own
machines. The included worker deterministically returns `input.upper()`.

## Run it

```bash
uv sync
uv run uvicorn main:app --reload
```

Open <http://127.0.0.1:8000/> for the token-based local dashboard. The default
database is `./agent-relay.db`; set `RELAY_DATABASE_URL` to use another SQLite
file. `GET /health` is a liveness check and `GET /ready` verifies database
connectivity and schema (it queries the real tables, so a wiped volume
reports not-ready instead of passing with zero tables).

Register two identities and send a task:

```bash
alice=$(curl -sS -X POST http://127.0.0.1:8000/api/v1/agents \
  -H 'content-type: application/json' -d '{"name":"alice"}')
bob=$(curl -sS -X POST http://127.0.0.1:8000/api/v1/agents \
  -H 'content-type: application/json' -d '{"name":"uppercase"}')
```

The response contains each agent's secret `token` once. Keep it outside source
control. Use `Authorization: Bearer <token>` for all subsequent API calls;
registration is the only unauthenticated endpoint. For a shared installation,
set `RELAY_ENROLLMENT_SECRET` and send it as `X-Enrollment-Secret` when
registering.

## Run the deterministic worker

The worker can register itself and save credentials in a mode-0600 JSON file:

```bash
uv run python main.py worker \
  --base-url http://127.0.0.1:8000 \
  --name uppercase \
  --credentials ./uppercase-credentials.json \
  --worker-id laptop-1
```

For failure/redelivery demonstrations, make local execution intentionally slow
and stop the process after one completion:

```bash
uv run python main.py worker --credentials ./uppercase-credentials.json \
  --slow-seconds 75 --worker-id slow-laptop
```

The worker heartbeats during long work. Killing it leaves the claim leased;
after the 60-second lease expires, another worker can claim the task with a new
token and incremented attempt number. `RELAY_LEASE_SECONDS` and
`RELAY_MAX_ATTEMPTS` are configurable server settings.

An existing credential can also be supplied explicitly (the token is not
written to disk):

```bash
uv run python main.py worker --agent-id agent_123 --token agt_… --worker-id laptop-2
```

## Storage and delivery behavior

`database.py` contains SQLAlchemy models, SQLite WAL setup, and the isolated
`BEGIN IMMEDIATE` transaction helper. `storage.py` contains task/claim/recovery
operations; routes and request models are kept in `main.py` and `schemas.py`.
SQLite does not provide PostgreSQL's `FOR UPDATE SKIP LOCKED`, so the starter
serializes writer transactions to make concurrent claims safe across processes.
Students can port this storage seam to PostgreSQL later without changing the
HTTP protocol or lifecycle in `SPEC.md`.

Claims are at-least-once and leased for 60 seconds by default. Heartbeats extend
an active lease. A completion or failure must include the recipient's bearer
token and claim token. Repeating the exact terminal request with that claim
token is idempotent; a stale token or different result receives `409`.

## Verify

The test suite covers the main protocol, sender/recipient access boundaries,
hashed claim-token behavior, idempotent terminal retries, concurrent claims,
lease expiry before and after recovery, pagination/error shape, and dashboard
asset serving:

```bash
uv run pytest -q
```

Tests default to a scratch database at `/tmp/agent-relay-test.db` so they
don't reset your dev server's `./agent-relay.db`. The fixture drops and
recreates all tables on whatever `RELAY_DATABASE_URL` points at, so stop
the dev server first or set `RELAY_DATABASE_URL` to a scratch file before
running tests against another database.

This starter intentionally does not include Docker, Kubernetes, CI, external
brokers, an LLM, or a PostgreSQL implementation. Those are deployment and
student-port concerns rather than part of the local relay protocol.

## Live API integration test (homework question 2)

Start the API as described above, then run in a second terminal:

```bash
RELAY_TEST_BASE_URL=http://127.0.0.1:8000 uv run pytest -q test_live_api.py
```

This test registers two unique agents and exercises queued → processing →
completed through real HTTP requests and the server's database. The test acts
as the recipient, claims the task, and submits the uppercase result; a separate
worker is not required. It verifies the sender can read the result and delivery
history. It never resets the server database. Each run leaves two test agents
and one task in the database; their credentials are kept only in test memory.
Your existing dashboard identity still shows its own tasks.

Set `RELAY_TEST_BASE_URL` to the published API URL to reuse this test with
Docker, Compose, or a Kubernetes port forward. If enrollment is protected,
also set `RELAY_TEST_ENROLLMENT_SECRET`. Without `RELAY_TEST_BASE_URL`, this
test is skipped so the starter tests can run without a server.
