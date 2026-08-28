#!/usr/bin/env bash

# Start SSH server if PUBLIC_KEY is set (enables remote access and dev-sync.sh)
if [ -n "$PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh
    echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys

    # Generate host keys if they don't exist (removed during image build for security)
    for key_type in rsa ecdsa ed25519; do
        key_file="/etc/ssh/ssh_host_${key_type}_key"
        if [ ! -f "$key_file" ]; then
            ssh-keygen -t "$key_type" -f "$key_file" -q -N ''
        fi
    done

    service ssh start && echo "worker-comfyui: SSH server started" || echo "worker-comfyui: SSH server could not be started" >&2
fi

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# ---------------------------------------------------------------------------
# GPU pre-flight check
# Verify that the GPU is accessible before starting ComfyUI. If PyTorch
# cannot initialize CUDA the worker will never be able to process jobs,
# so we fail fast with an actionable error message.
# ---------------------------------------------------------------------------
echo "worker-comfyui: Checking GPU availability..."
if ! GPU_CHECK=$(python3 -c "
import torch
try:
    torch.cuda.init()
    name = torch.cuda.get_device_name(0)
    cap = torch.cuda.get_device_capability(0)
    # Launch a real kernel. The driver-only calls above succeed even when this
    # PyTorch build has no compiled kernels for the GPU architecture (e.g. an
    # older torch on a newer GPU). Without this, the worker boots, ComfyUI dies
    # on the first GPU op, and it surfaces as the misleading 'server not
    # reachable' error instead of a clear cause here.
    _ = (torch.zeros(8, device='cuda') + 1).sum().item()
    torch.cuda.synchronize()
    print(f'OK: {name} (sm_{cap[0]}{cap[1]}), torch {torch.__version__}, cuda {torch.version.cuda}')
except Exception as e:
    print(f'FAIL: {e}')
    exit(1)
" 2>&1); then
    echo "worker-comfyui: GPU is not available or incompatible with this PyTorch build:"
    echo "worker-comfyui: $GPU_CHECK"
    echo "worker-comfyui: A 'no kernel image is available' error means this torch build"
    echo "worker-comfyui: lacks kernels for this GPU. Otherwise the GPU may not be"
    echo "worker-comfyui: properly initialized — please contact RunPod support."
    exit 1
fi
echo "worker-comfyui: GPU available — $GPU_CHECK"

# Ensure ComfyUI-Manager runs in offline network mode inside the container
comfy-manager-set-mode offline || echo "worker-comfyui - Could not set ComfyUI-Manager network_mode" >&2

# ── FAST: verify network volume + mount + extra paths before launching ──
# In darkcoal-qwen-fast the 3 uncensored GGUFs are NOT baked; they live on /runpod-volume.
if [ "${USE_NETWORK_VOLUME:-true}" = "true" ]; then
  # 0) Is the volume actually attached? /runpod-volume missing => endpoint misconfigured.
  if [ ! -d /runpod-volume ]; then
    echo "worker-comfyui: FATAL — /runpod-volume does not exist (network volume NOT attached to this endpoint)." >&2
    echo "worker-comfyui: Fix: RunPod Console → Serverless → your endpoint → Manage → Edit → Advanced → Network Volume → select qwen-fast-models → Save." >&2
    echo "worker-comfyui: Continuing anyway so diagnostics still run, but every GGUF request will 400 until the volume is attached." >&2
  elif ! mount 2>/dev/null | grep -q " /runpod-volume " && ! df /runpod-volume >/dev/null 2>&1; then
    echo "worker-comfyui: WARNING — /runpod-volume exists but does not look like a mount (may be empty container dir)." >&2
    echo "worker-comfyui: If this is a Pod, volume may be at /workspace instead — check df -h." >&2
    df -h /runpod-volume 2>&1 | sed 's/^/worker-comfyui:   /' || true
  fi

  # 1) Check individual expected files
  MISSING=""
  for f in \
    "/runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf" \
    "/runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf" \
    "/runpod-volume/models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf" \
    "/runpod-volume/models/vae/qwen_image_vae.safetensors"
  do
    [ -f "$f" ] || MISSING="$MISSING $f"
  done
  if [ -n "$MISSING" ]; then
    echo "worker-comfyui: FATAL — USE_NETWORK_VOLUME=true but missing on /runpod-volume:$MISSING" >&2
    echo "worker-comfyui: Attach the network volume with the qwen uncensored GGUFs and retry." >&2
    echo "worker-comfyui: The volume was set up with this exact layout — re-run this if Pod went cold:" >&2
    echo 'worker-comfyui:   mkdir -p /runpod-volume/models/text_encoders /runpod-volume/models/diffusion_models /runpod-volume/models/vae /runpod-volume/models/loras' >&2
    echo 'worker-comfyui:   curl -L -C - -o /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf          https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf' >&2
    echo 'worker-comfyui:   curl -L -C - -o /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf    https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf' >&2
    echo 'worker-comfyui:   curl -L -C - -o /runpod-volume/models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf  https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf' >&2
    echo 'worker-comfyui:   curl -L -C - -o /runpod-volume/models/vae/qwen_image_vae.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors' >&2
    echo "worker-comfyui: See PLAN.md §3 or docs/network-volumes.md" >&2
    echo "worker-comfyui: Continuing anyway (ComfyUI will fail to find those models) ..." >&2
  else
    echo "worker-comfyui: FAST volume check OK — uncensored GGUFs present on /runpod-volume"
    ls -lh /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf \
           /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf \
           /runpod-volume/models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf \
           /runpod-volume/models/vae/qwen_image_vae.safetensors  2>&1 | sed 's/^/worker-comfyui:   /'
  fi

  # 2) Verify extra_model_paths.yaml is baked where ComfyUI expects it
  if [ ! -f /comfyui/extra_model_paths.yaml ]; then
    echo "worker-comfyui: FATAL — /comfyui/extra_model_paths.yaml missing (build bug, volume won't be scanned)." >&2
  else
    echo "worker-comfyui: extra_model_paths.yaml present:"; sed 's/^/worker-comfyui:   /' /comfyui/extra_model_paths.yaml 2>&1
  fi

  # 3) Verify ComfyUI-GGUF node actually imported (works even before ComfyUI starts)
  if python3 -c "import importlib.util; exit(0 if importlib.util.find_spec('gguf') else 1)" 2>/dev/null; then
    echo "worker-comfyui: gguf Python package OK ($(python3 -c 'import gguf; print(gguf.__version__)' 2>&1))"
  else
    echo "worker-comfyui: WARNING — gguf pip package not importable (ComfyUI-GGUF nodes will fail to import)." >&2
  fi
  if [ ! -d /comfyui/custom_nodes/ComfyUI-GGUF ]; then
    echo "worker-comfyui: WARNING — /comfyui/custom_nodes/ComfyUI-GGUF missing (UnetLoaderGGUF/CLIPLoaderGGUF won't exist, lists will be empty)." >&2
    echo "worker-comfyui: Check Dockerfile GGUF install step." >&2
  else
    echo "worker-comfyui: ComfyUI-GGUF nodes present at /comfyui/custom_nodes/ComfyUI-GGUF"
  fi
fi

echo "worker-comfyui: Starting ComfyUI"

# Allow operators to tweak verbosity; default is DEBUG.
: "${COMFY_LOG_LEVEL:=DEBUG}"

# PID file used by the handler to detect if ComfyUI is still running
COMFY_PID_FILE="/tmp/comfyui.pid"

# Serve the API and don't shutdown the container
if [ "$SERVE_API_LOCALLY" == "true" ]; then
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py
fi