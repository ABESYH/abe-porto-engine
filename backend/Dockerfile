FROM python:3.11-slim

WORKDIR /app
RUN useradd -m appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

ARG APP_VERSION=v1.0.0-local
ENV APP_VERSION=$APP_VERSION

COPY main.py video_ltx2_3_i2v_workflow.json* .

USER appuser
EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]