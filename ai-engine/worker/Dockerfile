ARG REGISTRY_NAMESPACE
FROM ${REGISTRY_NAMESPACE}/ai-engine-base:latest

WORKDIR /app

# Copy lightweight worker runtime files (proprietary app files omitted from public archive)
COPY . .

CMD ["python3", "-u", "/app/worker.py"]