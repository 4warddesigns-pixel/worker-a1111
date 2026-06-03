# TEST DOCKERFILE — validates the core A1111 build step in isolation
# Skips: model download (Stage 1), handler src, requirements.txt
# Purpose: fast feedback loop — confirm git clone + prepare_environment passes
#          before running the full slow build
#
# Build command:
#   docker build -f "Test Dockerfile" . --progress=plain --no-cache
#
# Success: last printed line will be --- CORE BUILD STEP PASSED ---
# Failure: docker will print the exact line that errored and exit non-zero

FROM python:3.10.14-slim

ARG A1111_RELEASE=v1.9.3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    ROOT=/stable-diffusion-webui \
    PYTHONUNBUFFERED=1 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/echo

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt install -y \
    fonts-dejavu-core rsync git jq moreutils aria2 wget libgoogle-perftools-dev libtcmalloc-minimal4 procps libgl1 libglib2.0-0 && \
    apt-get autoremove -y && rm -rf /var/lib/apt/lists/* && apt-get clean -y

RUN echo "--- APT STEP PASSED ---"

RUN --mount=type=cache,target=/root/.cache/pip \
    git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git && \
    cd stable-diffusion-webui && \
    git reset --hard ${A1111_RELEASE} && \
    pip install --upgrade pip && \
    pip install torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --extra-index-url https://download.pytorch.org/whl/cu124 && \
    pip install xformers && \
    pip install -r requirements_versions.txt && \
    mkdir -p repositories && \
    git clone --depth 1 https://github.com/AUTOMATIC1111/stable-diffusion-webui-assets repositories/stable-diffusion-webui-assets && \
    git clone --depth 1 https://github.com/Stability-AI/stablediffusion repositories/stable-diffusion-stability-ai && \
    git clone --depth 1 https://github.com/Stability-AI/generative-models repositories/generative-models && \
    git clone --depth 1 https://github.com/crowsonkb/k-diffusion repositories/k-diffusion && \
    git clone --depth 1 https://github.com/sczhou/CodeFormer repositories/CodeFormer && \
    git clone --depth 1 https://github.com/salesforce/BLIP repositories/BLIP && \
    python -c "from launch import prepare_environment; prepare_environment()" --skip-torch-cuda-test --skip-git-pull

RUN echo "--- CORE BUILD STEP PASSED ---"
