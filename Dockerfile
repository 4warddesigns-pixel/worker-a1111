# DOCKERFILE-TEST-UI — experimental rebuild using ComfyUI worker's approach
# Goal: bypass all cascading pip/setuptools/CLIP ecosystem drift by switching to:
#   - nvidia/cuda CUDA base image (not python:slim) — matches GPU environment natively
#   - uv package manager (not pip) — handles build isolation and pkg_resources cleanly
#   - Python 3.10 from Ubuntu 22.04 native (matches A1111 v1.9.3 tested environment)
#   - setuptools + wheel installed from the start into a clean venv
#
# Based on pattern from runpod-workers/worker-comfyui (confirmed working on RunPod)
# Stage 1 (model download) is omitted for test speed — identical to production
#
# Build command:
#   docker build -f Dockerfile-test-UI.txt . --progress=plain --no-cache
#
# Success: last lines will be import checks then --- UI APPROACH VERIFIED ---
# Failure: docker prints the exact failing line and exits non-zero
#
# If this build goes green, the same Stage 2 replaces the current GitHub Dockerfile.
# Stage 1 (wget Deliberate_v6.safetensors) and all src/ files stay unchanged.

# ---------------------------------------------------------------------------- #
#                        Stage 2: Build the final image                        #
# ---------------------------------------------------------------------------- #
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04 as build_final_image

ARG A1111_RELEASE=v1.9.3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    ROOT=/stable-diffusion-webui \
    PYTHONUNBUFFERED=1 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/echo \
    PATH="/opt/venv/bin:${PATH}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# System deps — same as before plus python3-venv for uv venv creation
RUN apt-get update && \
    apt-get install -y \
    python3 python3-pip python3-venv python-is-python3 \
    fonts-dejavu-core rsync git jq moreutils aria2 wget \
    libgoogle-perftools-dev libtcmalloc-minimal4 procps libgl1 libglib2.0-0 && \
    apt-get autoremove -y && rm -rf /var/lib/apt/lists/* && apt-get clean -y

RUN echo "--- APT STEP PASSED ---"

# Install uv (modern Rust-based package manager — handles build isolation cleanly)
RUN wget -qO- https://astral.sh/uv/install.sh | sh && \
    ln -s /root/.local/bin/uv /usr/local/bin/uv

# Create isolated venv and put it on PATH (set in ENV above)
RUN uv venv /opt/venv

# Install pip, setuptools, wheel first — same pattern as ComfyUI worker.
# setuptools pinned to 68.2.2: last version with full pkg_resources support.
# CLIP's setup.py does "import pkg_resources" — setuptools 70+ breaks this.
RUN uv pip install pip "setuptools==68.2.2" wheel

RUN echo "--- UV + VENV STEP PASSED ---"

# PyTorch — explicit CUDA 12.4 build (matches base image)
RUN uv pip install \
    torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 \
    --index-url https://download.pytorch.org/whl/cu124

# xformers — pinned to correct build for torch 2.6.0
RUN uv pip install xformers==0.0.29.post3

RUN echo "--- TORCH STEP PASSED ---"

# Pre-install packages A1111 prepare_environment installs poorly with old pip:
#   - CLIP: old setup.py uses pkg_resources — uv handles this cleanly
#   - dctorch: k-diffusion imports it, not in requirements.txt
#   - taming-transformers + latent-diffusion: make ldm importable as a real package
RUN uv pip install \
    "https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip" \
    dctorch \
    git+https://github.com/CompVis/taming-transformers.git \
    git+https://github.com/CompVis/latent-diffusion.git

RUN echo "--- PRE-INSTALL STEP PASSED ---"

# Clone A1111 and install its Python requirements
RUN git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git && \
    cd stable-diffusion-webui && \
    git reset --hard ${A1111_RELEASE} && \
    uv pip install -r requirements_versions.txt

RUN echo "--- A1111 REQUIREMENTS STEP PASSED ---"

# Clone repositories A1111 needs at runtime.
# stable-diffusion-stability-ai: cloned from CompVis (same code, Stability-AI is private).
#   Remote URL spoofed to Stability-AI so prepare_environment URL check passes.
# generative-models: not needed for SD 1.x — stub git repo with correct remote
#   so prepare_environment URL check passes without fetching.
RUN cd stable-diffusion-webui && \
    mkdir -p repositories && \
    git clone --depth 1 https://github.com/AUTOMATIC1111/stable-diffusion-webui-assets repositories/stable-diffusion-webui-assets && \
    git clone --depth 1 https://github.com/CompVis/stable-diffusion repositories/stable-diffusion-stability-ai && \
    git -C repositories/stable-diffusion-stability-ai remote set-url origin https://github.com/Stability-AI/stablediffusion && \
    mkdir -p repositories/generative-models && \
    git -C repositories/generative-models init && \
    git -C repositories/generative-models remote add origin https://github.com/Stability-AI/generative-models && \
    git clone --depth 1 https://github.com/crowsonkb/k-diffusion repositories/k-diffusion && \
    git clone --depth 1 https://github.com/sczhou/CodeFormer repositories/CodeFormer && \
    git clone --depth 1 https://github.com/salesforce/BLIP repositories/BLIP

RUN echo "--- REPOSITORIES STEP PASSED ---"

# Run prepare_environment to complete A1111 setup.
# --skip-torch-cuda-test: no GPU at build time
# --skip-git-pull: repos already cloned, remote URLs spoofed above
RUN cd stable-diffusion-webui && \
    python -c "from launch import prepare_environment; prepare_environment()" \
    --skip-torch-cuda-test --skip-git-pull

RUN echo "--- PREPARE_ENVIRONMENT STEP PASSED ---"

# Verify the three modules that caused runtime failures in old approach
RUN python -c "import ldm.modules.midas; print('OK: ldm.modules.midas')" && \
    python -c "import dctorch; print('OK: dctorch')" && \
    python -c "import xformers; print('OK: xformers', xformers.__version__)" && \
    python -c "import clip; print('OK: clip')"

RUN echo "--- UI APPROACH VERIFIED ---"
