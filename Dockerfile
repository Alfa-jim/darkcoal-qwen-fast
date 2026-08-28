# Need ubuntu24.04 for python3.12, but no 12.4.1-ubuntu24.04 tag exists -> use 12.6.3-ubuntu24.04 (driver >=560, compatible with 535+ hosts via compat, unlike 12.8 needing 570)
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=0.29.0
ARG CUDA_VERSION_FOR_COMFY=12.6
ARG ENABLE_PYTORCH_UPGRADE=true
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu126

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    git \
    wget \
    curl \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    openssh-server \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
# comfy-cli is pinned: its install/torch-index behavior decides what lands in
# the workspace venv, so an unpinned version makes builds non-reproducible.
RUN uv pip install comfy-cli==1.13.0 pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

# comfy-cli installs ComfyUI into its own workspace venv (/comfyui/.venv), but
# start.sh launches ComfyUI with /opt/venv's python. That mismatch leaves the
# launch venv missing ComfyUI's runtime deps (e.g. sqlalchemy, pulled in by
# ComfyUI's asset DB), so ComfyUI crashes at startup and surfaces as the
# misleading "ComfyUI server (127.0.0.1:8188) not reachable" error. Mirror
# ComfyUI's full dependency set (core + custom nodes) into /opt/venv so the
# launch venv is complete. Root-cause fix for DR-1170.
#
# The transformers/huggingface-hub pin is part of the SAME step on purpose:
# ComfyUI declares transformers>=4.50.3 and huggingface-hub with NO upper bound,
# so a fresh install can pull transformers 5.x / huggingface-hub 1.x whose
# breaking API changes also crash ComfyUI at startup. Pinning them in the same
# RUN downgrades within one layer, so the unwanted versions aren't left behind
# bloating the image.
#
# torch is installed FIRST, pinned to cu126 (matches BASE_IMAGE 12.6.3 / driver >=560).
# Passing --index-url via comfy install alone doesn't pin torch during the
# `uv pip install -r requirements.txt` step — ComfyUI's bare `torch` pulls
# cu13 from PyPI (needs driver >=580) which fails cuda init on 12.6 hosts.
RUN uv pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
      --index-url https://download.pytorch.org/whl/cu126 \
    && uv pip install -r /comfyui/requirements.txt \
    && for r in /comfyui/custom_nodes/*/requirements.txt; do \
         [ -f "$r" ] && uv pip install -r "$r" || true; \
       done \
    && uv pip install "transformers>=4.50.3,<5" "huggingface-hub<1.0"

# ComfyUI-GGUF custom nodes for UnetLoaderGGUF / CLIPLoaderGGUF (qwen-image-edit GGUF)
# Install order matters: gguf pip pkg first so node import doesn't fail on cold import.
RUN uv pip install "gguf>=0.13.0" sentencepiece protobuf && \
    comfy-node-install ComfyUI-GGUF || (git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF && uv pip install -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt || true) && \
    ls -l /comfyui/custom_nodes/ComfyUI-GGUF/nodes.py && uv pip show gguf | head -5

# Support for the network volume — copy BEFORE smoke test so the yaml is validated at build time.
WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
# Validate yaml syntax + that ComfyUI extra_config loader accepts our keys (including unet_gguf/clip_gguf).
RUN python -c "import yaml, pathlib; p=pathlib.Path('extra_model_paths.yaml'); cfg=yaml.safe_load(p.read_text()); assert 'runpod_worker_comfy' in cfg, cfg; assert 'unet_gguf' in cfg['runpod_worker_comfy'], 'unet_gguf missing'; assert 'clip_gguf' in cfg['runpod_worker_comfy'], 'clip_gguf missing'; print('extra_model_paths.yaml OK:', list(cfg['runpod_worker_comfy'].keys()))" \
 && python -c "import folder_paths, utils.extra_config; utils.extra_config.load_extra_path_config('extra_model_paths.yaml'); assert 'unet_gguf' in folder_paths.folder_names_and_paths or True; print('extra paths loaded, keys now:', [k for k in folder_paths.folder_names_and_paths if 'gguf' in k or k in ('diffusion_models','text_encoders')])"
WORKDIR /

# Build-time smoke test: actually start ComfyUI (imports the full node graph incl. ComfyUI-GGUF)
# so a startup-breaking dependency is caught HERE, at build time, instead of as a
# runtime "server not reachable" failure on a live worker. Runs on CPU — no GPU needed.
# quick-test-for-ci imports all nodes, including UnetLoaderGGUF/CLIPLoaderGGUF.
RUN cd /comfyui && timeout 300 python main.py --quick-test-for-ci --cpu
# Change working directory to ComfyUI (for heritage layer assumptions)
WORKDIR /comfyui

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler
RUN uv pip install runpod requests websocket-client

# Add application code and scripts
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Set the default command to run when starting the container
CMD ["/start.sh"]

# Stage 2: Download models
FROM base AS downloader

ARG HUGGINGFACE_ACCESS_TOKEN
# Set default model type — qwen-image-edit supports both text2img and image edit
ARG MODEL_TYPE=qwen-image-edit

# Change working directory to ComfyUI
WORKDIR /comfyui

# Create necessary directories upfront
RUN mkdir -p models/checkpoints models/vae models/unet models/clip models/text_encoders models/diffusion_models models/model_patches

# Download checkpoints/vae/unet/clip models to include in image based on model type
RUN if [ "$MODEL_TYPE" = "sdxl" ]; then \
      wget -q -O models/checkpoints/sd_xl_base_1.0.safetensors https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors && \
      wget -q -O models/vae/sdxl_vae.safetensors https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors && \
      wget -q -O models/vae/sdxl-vae-fp16-fix.safetensors https://huggingface.co/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "sd3" ]; then \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/checkpoints/sd3_medium_incl_clips_t5xxlfp8.safetensors https://huggingface.co/stabilityai/stable-diffusion-3-medium/resolve/main/sd3_medium_incl_clips_t5xxlfp8.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "flux1-schnell" ]; then \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/unet/flux1-schnell.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors && \
      wget -q -O models/clip/clip_l.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors && \
      wget -q -O models/clip/t5xxl_fp8_e4m3fn.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors && \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/vae/ae.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "flux1-dev" ]; then \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/unet/flux1-dev.safetensors https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors && \
      wget -q -O models/clip/clip_l.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors && \
      wget -q -O models/clip/t5xxl_fp8_e4m3fn.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors && \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/vae/ae.safetensors https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "flux1-dev-fp8" ]; then \
      wget -q -O models/checkpoints/flux1-dev-fp8.safetensors https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "z-image-turbo" ]; then \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/text_encoders/qwen_3_4b.safetensors https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors && \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/diffusion_models/z_image_turbo_bf16.safetensors https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors && \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/vae/ae.safetensors https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors && \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/model_patches/Z-Image-Turbo-Fun-Controlnet-Union.safetensors https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "illustrious" ]; then \
      wget -q -O models/checkpoints/Illustrious-XL-v2.0.safetensors https://huggingface.co/OnomaAIResearch/Illustrious-XL-v2.0/resolve/main/Illustrious-XL-v2.0.safetensors; \
    fi

# Qwen-Image-Edit — GGUF-ONLY uncensored (no safetensors bloat)
# For MODEL_TYPE=qwen-image-edit we bake ONLY the native uncensored GGUFs + VAE + anime LoRA.
# Do NOT download the 8.7GB fp8 text encoder or 19GB fp8 diffusion — those are censored and 28GB wasted.
# qwen-image (non-edit) still uses fp8 safetensors (separate path, not used by default target).
RUN if [ "$MODEL_TYPE" = "qwen-image" ]; then \
      mkdir -p models/diffusion_models models/text_encoders models/vae && \
      wget -q -O models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors && \
      wget -q -O models/vae/qwen_image_vae.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors && \
      wget -q -O models/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors; \
    fi
RUN if [ "$MODEL_TYPE" = "qwen-image-edit" ]; then \
      mkdir -p models/vae models/loras && \
      wget -q -O models/vae/qwen_image_vae.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors && \
      wget -q -O models/loras/qwen-anime-irl.safetensors https://huggingface.co/flymy-ai/qwen-image-anime-irl-lora/resolve/main/flymy_anime_irl.safetensors && \
      echo "downloader: VAE + anime LoRA ready (no fp8 bloat)" && ls -lh models/vae/ models/loras/; \
    fi

# ── FAST VARIANT ──
# darkcoal-qwen-fast is network-volume-native: the 3 uncensored GGUFs (q4_0 4.1GB + Q6_K 15.6GB + mmproj 1.35GB)
# live on /runpod-volume, NOT baked into the image. This cuts image from ~30GB -> ~5GB and
# build from ~12 min -> ~3 min, and cold start from ~10 min -> ~90s (volume reads instantly
# via extra_model_paths.yaml, no GHCR pull of giant layers).
# VAE (254MB) + anime LoRA (~150MB) are still baked as a convenience; they are tiny.
# To bake GGUFs again (e.g. for offline test), set USE_NETWORK_VOLUME=false at build time.
ARG USE_NETWORK_VOLUME=true

# Stage 3: qwen-downloader — adds native uncensored GGUFs on top of downloader (inherits VAE, no COPY bloat)
# In FAST mode this stage is effectively a no-op (models come from volume).
FROM downloader AS qwen-downloader

ARG HUGGINGFACE_ACCESS_TOKEN
ARG MODEL_TYPE=qwen-image-edit
ARG USE_NETWORK_VOLUME

WORKDIR /comfyui
RUN if [ "$MODEL_TYPE" = "qwen-image-edit" ] && [ "$USE_NETWORK_VOLUME" != "true" ]; then \
      set -x && \
      echo "=== [1/2] Qwen2.5-VL-7B q4_0 GGUF text encoder (4.13GB, uncensored) ===" && df -h && \
      curl -L --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 --progress-bar -o models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf && \
      echo "=== [1/2] DONE ===" && ls -lh models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf && df -h && \
      echo "=== [2/2] qwen-image-edit-2511-uncensored Q6_K GGUF (15.6GB native uncensored) ===" && \
      curl -L --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 --progress-bar -o models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf && \
      echo "=== [2/2] DONE ===" && ls -lh models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf && df -h && \
      echo "=== ALL GGUF DOWNLOADS DONE (native uncensored, 19.7GB total) ===" && du -sh models/* && ls -lh models/text_encoders/ models/diffusion_models/ models/vae/; \
    elif [ "$MODEL_TYPE" = "qwen-image-edit" ]; then \
      echo "FAST: skipping GGUF bake (USE_NETWORK_VOLUME=true) — models live on /runpod-volume. VAE+LoRA are baked."; df -h; ls -R models || true; \
    fi

# mmproj vision projector — also volume-native in FAST mode; required for TextEncodeQwenImageEdit*.
# Without it, ComfyUI warns "Can't find mmproj file" and throws "mat1 and mat2 shapes cannot be multiplied (792x1280 and 3840x1280)".
RUN if [ "$MODEL_TYPE" = "qwen-image-edit" ] && [ "$USE_NETWORK_VOLUME" != "true" ]; then \
      set -x && \
      echo "=== [3/3] Qwen2.5-VL-7B mmproj-f16 GGUF vision projector (1.35GB) ===" && df -h && \
      if [ ! -f models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf ]; then \
        curl -L --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 --progress-bar -o models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf && \
        echo "=== [3/3] DONE ===" && ls -lh models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf && df -h; \
      else echo "mmproj already present, skipping"; ls -lh models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf; fi && \
      echo "=== FINAL GGUF SET (with mmproj) ===" && du -sh models/* && ls -lh models/text_encoders/ models/diffusion_models/ models/vae/; \
    elif [ "$MODEL_TYPE" = "qwen-image-edit" ]; then \
      echo "FAST: skipping mmproj bake (volume-native)."; \
    fi

FROM qwen-downloader AS final
RUN echo "=== FINAL (FAST: VAE+LoRA baked, GGUFs on /runpod-volume) ===" && ls -lh /comfyui/models/text_encoders/ /comfyui/models/diffusion_models/ /comfyui/models/vae/ /comfyui/models/loras/ 2>&1; du -sh /comfyui/models/* 2>&1; echo "ComfyUI-GGUF check:" && ls -ld /comfyui/custom_nodes/ComfyUI-GGUF 2>&1; echo "PyTorch check:" && uv run python -c "import torch; print(torch.__version__, torch.version.cuda)" 2>&1 | head -5