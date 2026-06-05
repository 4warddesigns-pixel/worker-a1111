# DOCKERFILE-TEST — last tested state of Stage 2 for production Dockerfile
# GitHub repo: https://github.com/4warddesigns-pixel/worker-a1111
# Last build attempted: logs_72464941685 (June 5 2026) — failed only on
#   Stability-AI/stablediffusion auth (now fixed here with CompVis swap)
#
# RELATIONSHIP TO PRODUCTION DOCKERFILE:
#   This file IS Stage 2 of the production Dockerfile with all fixes applied.
#   Stage 1 (model download — Deliberate_v6.safetensors from HuggingFace) is
#   intentionally omitted to keep test builds fast. Everything from the main
#   RUN block onwards should match the production Dockerfile exactly.
#   COPY --from=download, requirements.txt, src/, start.sh, CMD are also
#   omitted — they live in the GitHub repo unchanged.
#
# FIXES APPLIED VS ORIGINAL GITHUB DOCKERFILE:
#   - GIT_TERMINAL_PROMPT=0 + GIT_ASKPASS=/bin/echo added to ENV
#   - torch==2.6.0 +cu124 pinned explicitly (was unpinned, pulled wrong version)
#   - xformers==0.0.29.post3 pinned (was unpinned — installed 0.0.29.post1
#     which was built for torch 2.5.1, causing xformers warning on every job)
#   - pip install dctorch added (k-diffusion imports it, not in requirements.txt)
#   - pip install taming-transformers + latent-diffusion added (makes ldm
#     importable as a proper package — bypasses A1111 sys.path wiring)
#   - CompVis/stable-diffusion replaces Stability-AI/stablediffusion
#     (Stability-AI repo went private June 2026 — auth error on git clone)
#   - generative-models stubbed with mkdir -p (SDXL repo, not needed for SD 1.x)
#   - --skip-git-pull added to prepare_environment() call (was missing —
#     without it, prepare_environment tries to re-clone repos including the
#     now-private Stability-AI ones)
#
# Build command:
#   docker build -f Dockerfile-test.txt . --progress=plain --no-cache
#
# Success: last lines will be import checks then --- IMPORT FIX VERIFIED ---
# Failure: docker will print the exact failing import and exit non-zero

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
    pip install --upgrade pip "setuptools==68.2.2" && \
    pip install torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --extra-index-url https://download.pytorch.org/whl/cu124 && \
    pip install xformers==0.0.29.post3 && \
    pip install dctorch \
                git+https://github.com/CompVis/taming-transformers.git \
                git+https://github.com/CompVis/latent-diffusion.git && \
    pip install -r requirements_versions.txt && \
    mkdir -p repositories && \
    git clone --depth 1 https://github.com/AUTOMATIC1111/stable-diffusion-webui-assets repositories/stable-diffusion-webui-assets && \
    git clone --depth 1 https://github.com/CompVis/stable-diffusion repositories/stable-diffusion-stability-ai && \
    mkdir -p repositories/generative-models && \
    git clone --depth 1 https://github.com/crowsonkb/k-diffusion repositories/k-diffusion && \
    git clone --depth 1 https://github.com/sczhou/CodeFormer repositories/CodeFormer && \
    git clone --depth 1 https://github.com/salesforce/BLIP repositories/BLIP && \
    pip install --no-build-isolation "https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip" && \
    python -c "from launch import prepare_environment; prepare_environment()" --skip-torch-cuda-test --skip-git-pull

RUN echo "--- CORE BUILD STEP PASSED ---"

# Verify the three modules that were failing at RunPod runtime
RUN python -c "import ldm.modules.midas; print('OK: ldm.modules.midas')" && \
    python -c "import dctorch; print('OK: dctorch')" && \
    python -c "import xformers; print('OK: xformers', xformers.__version__)"

RUN echo "--- IMPORT FIX VERIFIED ---"
