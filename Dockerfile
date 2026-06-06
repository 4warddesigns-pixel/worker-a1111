# DOCKERFILE-PRODUCTION-FULL — complete production Dockerfile with test markers
# Combines Stage 1 (model download) + Stage 2 (uv/CUDA build) + worker runtime files
# Once confirmed working on RunPod, create a clean copy without the echo markers.
#
# Stage 2 is identical to Dockerfile-test-UI.txt (the file used for fast iteration).
# Stage 1 and the runtime section (COPY model, ADD src, CMD) are restored from the
# last successful build: logs_72285265480 (June 4 2026).
#
# GitHub repo: https://github.com/4warddesigns-pixel/worker-a1111
# Docker Hub:  4warddesigners/worker-a1111:latest

# ---------------------------------------------------------------------------- #
#                        Stage 1: Download model                               #
# ---------------------------------------------------------------------------- #
FROM alpine:3 as download

ARG HF_TOKEN

RUN apk add --no-cache wget && \
    wget --server-response --header="Authorization: Bearer ${HF_TOKEN}" \
    -O /model.safetensors \
    https://huggingface.co/XpucT/Deliberate/resolve/main/Deliberate_v6.safetensors

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
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONPATH="/stable-diffusion-webui/repositories/stable-diffusion-stability-ai:/stable-diffusion-webui/repositories/generative-models"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y \
    python3 python3-pip python3-venv python-is-python3 \
    fonts-dejavu-core rsync git jq moreutils aria2 wget \
    libgoogle-perftools-dev libtcmalloc-minimal4 procps libgl1 libglib2.0-0 && \
    apt-get autoremove -y && rm -rf /var/lib/apt/lists/* && apt-get clean -y

RUN echo "--- APT STEP PASSED ---"

RUN wget -qO- https://astral.sh/uv/install.sh | sh && \
    ln -s /root/.local/bin/uv /usr/local/bin/uv

RUN uv venv /opt/venv

# setuptools pinned to 68.2.2: last version with full pkg_resources support.
# CLIP's setup.py does "import pkg_resources" — setuptools 70+ breaks this.
RUN uv pip install pip "setuptools==68.2.2" wheel

RUN echo "--- UV + VENV STEP PASSED ---"

RUN uv pip install \
    torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 \
    --index-url https://download.pytorch.org/whl/cu124

RUN uv pip install xformers==0.0.29.post3

RUN echo "--- TORCH STEP PASSED ---"

# CLIP: --no-build-isolation forces uv to use our pinned setuptools (68.2.2)
# instead of an isolated build env that gets a newer broken version.
RUN uv pip install --no-build-isolation \
    "https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip"

RUN uv pip install \
    dctorch \
    git+https://github.com/CompVis/taming-transformers.git

RUN echo "--- PRE-INSTALL STEP PASSED ---"

RUN git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git && \
    cd stable-diffusion-webui && \
    git reset --hard ${A1111_RELEASE} && \
    uv pip install -r requirements_versions.txt

RUN echo "--- A1111 REQUIREMENTS STEP PASSED ---"

# stable-diffusion-stability-ai: cloned from CompVis/latent-diffusion (parent framework,
#   has full ldm including ldm/modules/midas/ — CompVis/stable-diffusion lacks midas).
#   Remote URL spoofed to Stability-AI so prepare_environment URL check passes.
# generative-models: SD 2.x only — stub satisfies A1111 directory existence check.
RUN cd stable-diffusion-webui && \
    mkdir -p repositories && \
    git clone --depth 1 https://github.com/AUTOMATIC1111/stable-diffusion-webui-assets repositories/stable-diffusion-webui-assets && \
    git clone --depth 1 https://github.com/CompVis/latent-diffusion repositories/stable-diffusion-stability-ai && \
    git -C repositories/stable-diffusion-stability-ai remote set-url origin https://github.com/Stability-AI/stablediffusion && \
    mkdir -p repositories/generative-models && \
    git -C repositories/generative-models init && \
    git -C repositories/generative-models remote add origin https://github.com/Stability-AI/generative-models && \
    git clone --depth 1 https://github.com/crowsonkb/k-diffusion repositories/k-diffusion && \
    git clone --depth 1 https://github.com/sczhou/CodeFormer repositories/CodeFormer && \
    git clone --depth 1 https://github.com/salesforce/BLIP repositories/BLIP

RUN echo "--- REPOSITORIES STEP PASSED ---"

# ldm/modules/midas: Stability-AI addition for SD2 depth conditioning — not in any
# public CompVis repo. A1111 imports it unconditionally but never uses it for SD1.x.
RUN mkdir -p stable-diffusion-webui/repositories/stable-diffusion-stability-ai/ldm/modules/midas && \
    touch stable-diffusion-webui/repositories/stable-diffusion-stability-ai/ldm/modules/midas/__init__.py

RUN echo "--- MIDAS STUB CREATED ---"

# sgm/modules/encoders/modules: Stability-AI generative-models package — needed for SDXL
# but imported unconditionally by A1111 v1.9.3 initialize.py line 32. SD1.x never calls it.
RUN mkdir -p stable-diffusion-webui/repositories/generative-models/sgm/modules/encoders && \
    touch stable-diffusion-webui/repositories/generative-models/sgm/__init__.py && \
    touch stable-diffusion-webui/repositories/generative-models/sgm/modules/__init__.py && \
    touch stable-diffusion-webui/repositories/generative-models/sgm/modules/encoders/__init__.py && \
    touch stable-diffusion-webui/repositories/generative-models/sgm/modules/encoders/modules.py

RUN echo "--- SGM STUB CREATED ---"

# prepare_environment() removed: everything it installs is pre-installed above.
# It also does a git fetch against the now-private Stability-AI remote which fails
# even with --skip-git-pull (commit hash check is not gated by that flag).
RUN echo "--- PREPARE_ENVIRONMENT SKIPPED (all deps pre-installed) ---"

# Verify critical imports before baking the model in — fail fast if ldm is broken.
RUN python -c "import ldm.modules.midas; print('OK: ldm.modules.midas')" && \
    python -c "import sgm.modules.encoders.modules; print('OK: sgm.modules.encoders.modules')" && \
    python -c "import dctorch; print('OK: dctorch')" && \
    python -c "import xformers; print('OK: xformers', xformers.__version__)" && \
    python -c "import clip; print('OK: clip')"

RUN echo "--- UI APPROACH VERIFIED ---"

# ---------------------------------------------------------------------------- #
#                        Runtime: model + worker files                         #
# ---------------------------------------------------------------------------- #
COPY --from=download /model.safetensors /model.safetensors

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY test_input.json .
ADD src .
RUN chmod +x /start.sh

CMD ["/start.sh"]
