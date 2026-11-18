from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_health_endpoint_structure():
    res = client.get("/api/health")
    assert res.status_code in (200, 503)
    data = res.json()
    assert "status" in data
    assert data["components"]["api"] == "up"


def test_metrics_endpoint_available():
    res = client.get("/metrics")
    assert res.status_code == 200
    assert "http_request" in res.text


def test_generate_requires_input():
    res = client.post("/api/generate", data={"voice_lang": "en"})
    assert res.status_code == 400


def test_generate_rejects_invalid_passcode():
    res = client.post(
        "/api/generate",
        data={
            "preset_image_url": "https://example.com/sample.jpg",
            "voice_lang": "en",
            "passcode": "WRONG_PASSCODE",
        },
    )
    assert res.status_code == 401


def test_webhook_rejects_unauthorized_token():
    res = client.post(
        "/api/webhook?jobId=job_test&token=invalid_token",
        json={"status": "COMPLETED"},
    )
    assert res.status_code == 403