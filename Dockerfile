# ---------------------------------------------------------------------------- #
#                         Stage 1: Download the models                         #
# ---------------------------------------------------------------------------- #
FROM alpine/git:2.43.0 as download

# NOTE: CivitAI usually requires an API token, so you need to add it in the header
#       of the wget command if you're using a model from CivitAI.
RUN apk add --no-cache wget && \
    wget -q -O /model.safetensors https://huggingface.co/XpucT/Deliberate/resolve/main/Deliberate_v6.safetensors
# ---------------------------------------------------------------------------- #
#                        Stage 2: Build the final image                        #
# ---------------------------------------------------------------------------- #
FROM python:3.10.14-slim as build_final_image

ARG A1111_RELEASE=v1.9.3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    ROOT=/stable-diffusion-webui \
    PYTHONUNBUFFERED=1 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/echo \
    STABLE_DIFFUSION_REPO=https://github.com/CompVis/stable-diffusion

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt install -y \
    fonts-dejavu-core rsync git jq moreutils aria2 wget libgoogle-perftools-dev libtcmalloc-minimal4 procps libgl1 libglib2.0-0 && \
    apt-get autoremove -y && rm -rf /var/lib/apt/lists/* && apt-get clean -y

RUN --mount=type=cache,target=/root/.cache/pip \
    git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git && \
    cd stable-diffusion-webui && \
    git reset --hard ${A1111_RELEASE} && \
    pip install --upgrade pip wheel && \
    pip install "setuptools==67.8.0" && \
    pip install --no-build-isolation "git+https://github.com/openai/CLIP.git@d50d76daa670286dd6cacf3bcd80b5e4823fc8e1" && \
    pip install --upgrade setuptools && \
    pip install torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --extra-index-url https://download.pytorch.org/whl/cu124 && \
    pip install xformers==0.0.29.post1 --extra-index-url https://download.pytorch.org/whl/cu124 && \
    pip install -r requirements_versions.txt && \
    mkdir -p repositories && \
    git clone --depth 1 https://github.com/AUTOMATIC1111/stable-diffusion-webui-assets repositories/stable-diffusion-webui-assets && \
    git clone --depth 1 https://github.com/CompVis/stable-diffusion repositories/stable-diffusion-stability-ai && \
    export STABLE_DIFFUSION_COMMIT_HASH=$(git -C repositories/stable-diffusion-stability-ai rev-parse HEAD) && \
    git clone --depth 1 https://github.com/Stability-AI/generative-models repositories/generative-models && \
    export STABLE_DIFFUSION_XL_COMMIT_HASH=$(git -C repositories/generative-models rev-parse HEAD) && \
    git clone --depth 1 https://github.com/crowsonkb/k-diffusion repositories/k-diffusion && \
    export K_DIFFUSION_COMMIT_HASH=$(git -C repositories/k-diffusion rev-parse HEAD) && \
    git clone --depth 1 https://github.com/sczhou/CodeFormer repositories/CodeFormer && \
    export CODEFORMER_COMMIT_HASH=$(git -C repositories/CodeFormer rev-parse HEAD) && \
    git clone --depth 1 https://github.com/salesforce/BLIP repositories/BLIP && \
    export BLIP_COMMIT_HASH=$(git -C repositories/BLIP rev-parse HEAD) && \
    python -c "from launch import prepare_environment; prepare_environment()" --skip-torch-cuda-test --skip-git-pull

COPY --from=download /model.safetensors /model.safetensors

# install dependencies
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -r requirements.txt

COPY test_input.json .

ADD src .

RUN chmod +x /start.sh
CMD /start.sh
