import os
import json
import copy
import uuid
import time
import socket
import logging
import datetime
import requests
import psycopg2
import redis
from fastapi import FastAPI, UploadFile, File, Form, BackgroundTasks, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded


class JsonLogFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "level": record.levelname,
            "service": "abe-backend",
            "vm_hostname": socket.gethostname(),
            "message": record.getMessage(),
        }
        if hasattr(record, "job_id"):
            payload["job_id"] = record.job_id
        if hasattr(record, "event"):
            payload["event"] = record.event
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonLogFormatter())
logger = logging.getLogger("abe-backend")
logger.setLevel(logging.INFO)
logger.handlers = [handler]
logger.propagate = False

limiter = Limiter(key_func=get_remote_address)
app = FastAPI(title="Abe Porto Video Engine API")
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

Instrumentator().instrument(app).expose(app, endpoint="/metrics")

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_NAME = os.getenv("DB_NAME", "geneta_db")
DB_USER = os.getenv("DB_USER", "geneta_user")
DB_PASS = os.getenv("DB_PASS", "geneta_pass")
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")

VIP_PASSCODE = os.getenv("VIP_PASSCODE", "ABE2026")
GPU_API_KEY = os.getenv("GPU_API_KEY", "")
GPU_DISPATCH_URL = os.getenv("GPU_DISPATCH_URL", "")
GCS_BUCKET_NAME = os.getenv("GCS_BUCKET_NAME", "")
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://localhost:8080")
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "local-webhook-secret")
APP_VERSION = os.getenv("APP_VERSION", "v1.0.0")

MAX_IMAGE_BYTES = 10 * 1024 * 1024
ALLOWED_MIME_TYPES = {"image/jpeg", "image/png", "image/webp"}

VOICE_PROMPTS = {
    "id": (
        'A realistic cinematic vertical portrait video of the person looking directly at the camera '
        'with an amazed expression, speaking enthusiastically in Indonesian, '
        '"Gila, ini portonya keren banget!". Natural studio lighting, subtle head and hand gestures.'
    ),
    "en": (
        'A realistic cinematic vertical portrait video of the person looking directly at the camera '
        'with an amazed expression, speaking enthusiastically in English, '
        '"Whoa, this cloud portfolio is seriously impressive!". Natural studio lighting, subtle gestures.'
    ),
    "zh": (
        'A realistic cinematic vertical portrait video of the person looking directly at the camera '
        'with an amazed expression, speaking enthusiastically in Mandarin Chinese, '
        '"哇，这个云架构作品集太酷了！". Natural studio lighting, subtle gestures.'
    ),
}

WORKFLOW_PATH = "inference_workflow.json"
WORKFLOW_TEMPLATE = None
if os.path.exists(WORKFLOW_PATH):
    with open(WORKFLOW_PATH, "r") as f:
        WORKFLOW_TEMPLATE = json.load(f)


def get_workflow_template():
    global WORKFLOW_TEMPLATE
    if WORKFLOW_TEMPLATE is not None:
        return WORKFLOW_TEMPLATE
    if GCS_BUCKET_NAME:
        from google.cloud import storage

        client = storage.Client()
        blob = client.bucket(GCS_BUCKET_NAME).blob("config/inference_workflow.json")
        if blob.exists():
            WORKFLOW_TEMPLATE = json.loads(blob.download_as_text())
            logger.info("Loaded workflow template from private GCS bucket", extra={"event": "workflow_loaded_gcs"})
            return WORKFLOW_TEMPLATE
    return None


def sign_gcs_url(blob, method: str, expiration_minutes: int = 30, content_type: str = None):
    import google.auth
    from google.auth.transport.requests import Request as GoogleAuthRequest

    credentials, _ = google.auth.default()
    if not credentials.valid or not credentials.token:
        credentials.refresh(GoogleAuthRequest())

    kwargs = {
        "version": "v4",
        "expiration": datetime.timedelta(minutes=expiration_minutes),
        "method": method,
    }
    if content_type:
        kwargs["content_type"] = content_type

    if not hasattr(credentials, "signer"):
        kwargs["service_account_email"] = credentials.service_account_email
        kwargs["access_token"] = credentials.token

    return blob.generate_signed_url(**kwargs)


def get_db_connection():
    return psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS, connect_timeout=2)


@app.on_event("startup")
def init_db():
    for _ in range(3):
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS video_jobs (
                    job_id VARCHAR(64) PRIMARY KEY,
                    mode VARCHAR(30),
                    voice_lang VARCHAR(10),
                    status VARCHAR(30),
                    video_url TEXT,
                    served_by_vm VARCHAR(100),
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.commit()
            cur.close()
            conn.close()
            logger.info("Database schema verified", extra={"event": "startup_db_ready"})
            break
        except Exception as exc:
            logger.warning(f"Waiting for PostgreSQL: {exc}", extra={"event": "startup_db_retry"})
            time.sleep(1)


def run_simulation_worker(job_id: str):
    logger.info("Starting simulation render", extra={"job_id": job_id, "event": "simulation_start"})
    time.sleep(8)
    sample_video = "https://www.w3schools.com/html/mov_bbb.mp4"
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "UPDATE video_jobs SET status = %s, video_url = %s WHERE job_id = %s",
            ("completed", sample_video, job_id),
        )
        conn.commit()
        cur.close()
        conn.close()
        logger.info("Simulation render completed", extra={"job_id": job_id, "event": "simulation_completed"})
    except Exception as exc:
        logger.error(f"Simulation worker failed: {exc}", extra={"job_id": job_id, "event": "simulation_failed"})


@app.get("/api/health")
def health_check(response: Response):
    db_ok = False
    redis_ok = False

    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        db_ok = True
    except Exception:
        db_ok = False

    try:
        r = redis.Redis(host=REDIS_HOST, port=6379, socket_timeout=1)
        redis_ok = bool(r.ping())
    except Exception:
        redis_ok = False

    overall_healthy = db_ok and redis_ok
    if not overall_healthy:
        response.status_code = 503

    return {
        "status": "healthy" if overall_healthy else "degraded",
        "vm_hostname": socket.gethostname(),
        "version": APP_VERSION,
        "components": {
            "api": "up",
            "postgres": "up" if db_ok else "down",
            "redis": "up" if redis_ok else "down",
        },
    }


@app.post("/api/generate")
@limiter.limit("10/minute")
async def generate_video(
    request: Request,
    background_tasks: BackgroundTasks,
    image_file: UploadFile = File(None),
    preset_image_url: str = Form(""),
    voice_lang: str = Form("en"),
    passcode: str = Form(""),
):
    job_id = f"job_{uuid.uuid4().hex[:10]}"
    hostname = socket.gethostname()
    clean_lang = voice_lang if voice_lang in VOICE_PROMPTS else "en"

    if not image_file and not preset_image_url:
        raise HTTPException(status_code=400, detail="Input image or avatar selection is required.")

    img_bytes = None
    if image_file:
        if image_file.content_type not in ALLOWED_MIME_TYPES:
            raise HTTPException(status_code=400, detail="Unsupported file format. Use JPG, PNG, or WEBP.")
        img_bytes = await image_file.read()
        if len(img_bytes) > MAX_IMAGE_BYTES:
            raise HTTPException(status_code=400, detail="File size exceeds 10MB limit.")

    trimmed_passcode = passcode.strip()
    if trimmed_passcode and trimmed_passcode != VIP_PASSCODE:
        logger.warning("Rejected invalid GPU access passcode", extra={"job_id": job_id, "event": "auth_rejected"})
        raise HTTPException(status_code=401, detail="Invalid GPU access passcode.")

    use_gpu_worker = (trimmed_passcode == VIP_PASSCODE and bool(GPU_API_KEY) and bool(GPU_DISPATCH_URL))
    execution_mode = "SERVERLESS_GPU" if use_gpu_worker else "CLOUD_SIMULATION"

    try:
        r = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True, socket_timeout=1)
        r.set(f"job:{job_id}", "processing", ex=3600)
    except Exception as exc:
        logger.warning(f"Redis write skipped: {exc}", extra={"job_id": job_id, "event": "redis_warning"})

    out_path = f"outputs/{job_id}.mp4" if use_gpu_worker else None

    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO video_jobs (job_id, mode, voice_lang, status, video_url, served_by_vm) VALUES (%s, %s, %s, %s, %s, %s)",
            (job_id, execution_mode, clean_lang, "processing", out_path, hostname),
        )
        conn.commit()
        cur.close()
        conn.close()
    except Exception as exc:
        logger.error(f"DB insert failed: {exc}", extra={"job_id": job_id, "event": "db_error"})
        raise HTTPException(status_code=500, detail="Database persistence error.")

    logger.info(f"Job queued in {execution_mode}", extra={"job_id": job_id, "event": "job_queued"})

    if not use_gpu_worker:
        background_tasks.add_task(run_simulation_worker, job_id)
        return {
            "job_id": job_id,
            "status": "processing",
            "mode": execution_mode,
            "served_by_vm": hostname,
        }

    template = get_workflow_template()
    if not template:
        raise HTTPException(status_code=500, detail="Workflow template missing on server and GCS.")

    try:
        from google.cloud import storage

        storage_client = storage.Client()
        bucket = storage_client.bucket(GCS_BUCKET_NAME)

        input_image_url = preset_image_url
        if img_bytes:
            in_blob = bucket.blob(f"inputs/{job_id}.jpg")
            in_blob.upload_from_string(img_bytes, content_type=image_file.content_type or "image/jpeg")
            input_image_url = sign_gcs_url(in_blob, "GET", expiration_minutes=30)

        out_blob = bucket.blob(out_path)
        upload_url = sign_gcs_url(out_blob, "PUT", expiration_minutes=30, content_type="video/mp4")

        workflow_payload = copy.deepcopy(template)
        workflow_payload["320:328"]["inputs"]["value"] = False
        workflow_payload["269"]["inputs"]["image"] = f"input_{job_id}.jpg"
        workflow_payload["320:319"]["inputs"]["value"] = VOICE_PROMPTS[clean_lang]
        workflow_payload["320:301"]["inputs"]["value"] = 5
        workflow_payload["320:312"]["inputs"]["value"] = 720
        workflow_payload["320:299"]["inputs"]["value"] = 1280
        workflow_payload["320:276"]["inputs"]["noise_seed"] = 424242
        workflow_payload["320:277"]["inputs"]["noise_seed"] = 424242
        workflow_payload["75"]["inputs"]["filename_prefix"] = f"video/{job_id}"

        webhook_url = f"{PUBLIC_BASE_URL}/api/webhook?jobId={job_id}&token={WEBHOOK_SECRET}"
        resp = requests.post(
            GPU_DISPATCH_URL,
            headers={"Authorization": f"Bearer {GPU_API_KEY}", "Content-Type": "application/json"},
            json={
                "input": {
                    "workflow": workflow_payload,
                    "image_url": input_image_url,
                    "image_name": f"input_{job_id}.jpg",
                    "upload_url": upload_url,
                    "public_url": out_path,
                },
                "webhook": webhook_url,
            },
            timeout=15,
        )
        resp.raise_for_status()
        logger.info("Dispatched job to GPU worker", extra={"job_id": job_id, "event": "gpu_dispatched"})
        return {
            "job_id": job_id,
            "status": "processing",
            "mode": execution_mode,
            "served_by_vm": hostname,
        }
    except Exception as exc:
        logger.error(f"GPU dispatch error: {exc}", extra={"job_id": job_id, "event": "gpu_engine_dispatch_failed"})
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("UPDATE video_jobs SET status = %s WHERE job_id = %s", ("failed", job_id))
        conn.commit()
        cur.close()
        conn.close()
        raise HTTPException(status_code=500, detail="GPU inference dispatch failed.")


@app.post("/api/webhook")
async def worker_webhook(request: Request, jobId: str, token: str = ""):
    if token != WEBHOOK_SECRET:
        logger.warning("Rejected unauthorized webhook call", extra={"job_id": jobId, "event": "webhook_unauthorized"})
        raise HTTPException(status_code=403, detail="Invalid webhook token.")

    payload = await request.json()
    worker_status = payload.get("status", "COMPLETED")
    final_status = "completed" if worker_status == "COMPLETED" else "failed"

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        "UPDATE video_jobs SET status = %s WHERE job_id = %s",
        (final_status, jobId),
    )
    conn.commit()
    cur.close()
    conn.close()

    logger.info(f"Webhook updated job status to {final_status}", extra={"job_id": jobId, "event": "webhook_processed"})
    return {"received": True, "job_id": jobId, "status": final_status}


@app.get("/api/job/{job_id}")
def get_job_status(job_id: str):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        "SELECT job_id, mode, voice_lang, status, video_url, served_by_vm FROM video_jobs WHERE job_id = %s",
        (job_id,),
    )
    row = cur.fetchone()
    cur.close()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Job not found")

    video_url = row[4]
    if row[3] == "completed" and video_url and video_url.startswith("outputs/") and GCS_BUCKET_NAME:
        from google.cloud import storage

        client = storage.Client()
        blob = client.bucket(GCS_BUCKET_NAME).blob(video_url)
        video_url = sign_gcs_url(blob, "GET", expiration_minutes=60)

    return {
        "job_id": row[0],
        "mode": row[1],
        "voice_lang": row[2],
        "status": row[3],
        "video_url": video_url,
        "served_by_vm": row[5],
    }