"""Acceptance scenario 1 over HTTP against a running API and its real DB."""

import os
from uuid import uuid4

import httpx
import pytest


def test_live_task_round_trip():
    base_url = os.environ.get("RELAY_TEST_BASE_URL")
    if not base_url:
        pytest.skip("Set RELAY_TEST_BASE_URL to opt into the live API test")

    suffix = uuid4().hex[:12]
    enrollment = os.environ.get("RELAY_TEST_ENROLLMENT_SECRET")
    registration_headers = {"X-Enrollment-Secret": enrollment} if enrollment else {}

    # No app imports, mocked transports, or database resets: every operation
    # goes through the running server. Unique identities isolate each run.
    with httpx.Client(base_url=base_url.rstrip("/"), timeout=10) as client:
        assert client.get("/ready").status_code == 200

        def register(name):
            response = client.post(
                "/api/v1/agents",
                json={"name": f"integration-{name}-{suffix}"},
                headers=registration_headers,
            )
            assert response.status_code == 201
            identity = response.json()
            return identity["agent_id"], {"Authorization": f"Bearer {identity['token']}"}

        sender_id, sender_headers = register("sender")
        recipient_id, recipient_headers = register("recipient")
        response = client.post(
            "/api/v1/tasks",
            headers={**sender_headers, "Idempotency-Key": suffix},
            json={"to": recipient_id, "input": "hello integration test"},
        )
        assert response.status_code == 201
        assert response.json()["status"] == "queued"
        task_id = response.json()["task_id"]
        task_path = f"/api/v1/tasks/{task_id}"

        response = client.post(
            "/api/v1/tasks/claim",
            headers=recipient_headers,
            json={"worker_id": "integration-worker", "wait_seconds": 0},
        )
        assert response.status_code == 200
        claim = response.json()
        assert claim["task_id"] == task_id
        assert claim["from"] == sender_id
        assert claim["input"] == "hello integration test"
        assert claim["attempt"] == 1

        response = client.get(task_path, headers=sender_headers)
        assert response.status_code == 200
        assert response.json()["status"] == "processing"

        response = client.post(
            f"{task_path}/complete",
            headers=recipient_headers,
            json={"claim_token": claim["claim_token"], "output": claim["input"].upper()},
        )
        assert response.status_code == 200
        assert response.json()["status"] == "completed"

        response = client.get(task_path, headers=sender_headers)
        assert response.status_code == 200
        result = response.json()
        assert result["status"] == "completed"
        assert result["output"] == "HELLO INTEGRATION TEST"
        assert result["from"] == sender_id
        assert result["to"] == recipient_id
        assert result["error"] is None
        assert result["attempt_count"] == 1
        assert result["finished_at"] is not None

        response = client.get(f"{task_path}/attempts", headers=sender_headers)
        assert response.status_code == 200
        attempts = response.json()["items"]
        assert len(attempts) == 1
        assert attempts[0]["outcome"] == "completed"
        assert attempts[0]["worker_id"] == "integration-worker"
