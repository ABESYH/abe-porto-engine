FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

LABEL maintainer="abe-porto"
LABEL description="Base GPU inference runtime with pre-baked proprietary AI model weights"

ARG MODEL_CHECKPOINT_URL="https://registry.internal/models/base-video-model.safetensors"
ARG MODEL_ENCODER_URL="https://registry.internal/models/text-encoder.safetensors"
ARG MODEL_UPSCALER_URL="https://registry.internal/models/spatial-upscaler.safetensors"

# 1. System Dependencies & High-Speed Parallel Downloader
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    curl \
    aria2 \
    wget \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# 2. Prepare Runtime & Strip Unused UI/Manager Plugins to Minimize Cold-Boot Overhead
WORKDIR /engine
RUN mkdir -p \
    /engine/models/checkpoints \
    /engine/models/text_encoders \
    /engine/models/upscale_models \
    /engine/input \
    /engine/output

# 3. Pre-Bake Heavy Multi-GB Model Weights into Base Layer (Multi-Threaded aria2c)
# Proprietary model URLs are injected dynamically or cached on Persistent Disk during base build
RUN aria2c -x 16 -s 16 -k 1M -c --summary-interval=10 --console-log-level=warn \
    "${MODEL_CHECKPOINT_URL}" \
    -d /engine/models/checkpoints \
    -o base_model.safetensors

RUN aria2c -x 16 -s 16 -k 1M -c --summary-interval=10 --console-log-level=warn \
    "${MODEL_ENCODER_URL}" \
    -d /engine/models/text_encoders \
    -o text_encoder.safetensors

RUN aria2c -x 16 -s 16 -k 1M -c --summary-interval=10 --console-log-level=warn \
    "${MODEL_UPSCALER_URL}" \
    -d /engine/models/upscale_models \
    -o spatial_upscaler.safetensors