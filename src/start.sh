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
# In darkcoal-qwen-fast the 3 uncensored GGUFs are NOT baked; they live on a network volume.
# Serverless mounts at /runpod-volume, Pods often mount at /workspace — support both.
if [ "${USE_NETWORK_VOLUME:-true}" = "true" ]; then
  # Detect volume base path — prefer /runpod-volume, fall back to /workspace for Pods
  _VOL_BASE=""
  if [ -f "/runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf" ] || [ -f "/runpod-volume/models/diffusion_models/qwen-rapid-nsfw-v5.3-Q6_K.gguf" ] || [ -d /runpod-volume ]; then
    _VOL_BASE="/runpod-volume"
  elif [ -f "/workspace/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf" ] || [ -f "/workspace/models/diffusion_models/qwen-rapid-nsfw-v5.3-Q6_K.gguf" ] || [ -d /workspace ]; then
    _VOL_BASE="/workspace"
  fi
  # 0) Is the volume actually attached?
  if [ -z "$_VOL_BASE" ] || [ ! -d "$_VOL_BASE" ]; then
    echo "worker-comfyui: FATAL — no network volume found at /runpod-volume or /workspace (volume NOT attached)." >&2
    echo "worker-comfyui: Serverless: Attach at Advanced → Network Volume. Pod: set Mount Path to /runpod-volume." >&2
    echo "worker-comfyui: Continuing anyway so diagnostics still run, but every GGUF request will 400 until the volume is attached." >&2
  elif ! df "$_VOL_BASE" >/dev/null 2>&1; then
    echo "worker-comfyui: WARNING — $_VOL_BASE exists but does not look like a mount (may be empty dir)." >&2
    df -h 2>&1 | sed 's/^/worker-comfyui:   /' || true
  else
    echo "worker-comfyui: volume detected at $_VOL_BASE ($(df "$_VOL_BASE" | awk 'NR==2{print $1}'))" 2>&1 | sed 's/^/worker-comfyui:   /' || true
  fi
  # Fallback if still empty
  [ -n "$_VOL_BASE" ] || _VOL_BASE="/runpod-volume"

  # 1) Check individual expected files — PHIL Rapid-AIO (v53) + abliterated
  MISSING=""
  for f in \
    "$_VOL_BASE/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf" \
    "$_VOL_BASE/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.mmproj-f16.gguf" \
    "$_VOL_BASE/models/diffusion_models/qwen-rapid-nsfw-v5.3-Q6_K.gguf" \
    "$_VOL_BASE/models/vae/qwen_image_vae.safetensors"
  do
    [ -f "$f" ] || MISSING="$MISSING $f"
  done
  if [ -n "$MISSING" ]; then
    echo "worker-comfyui: FATAL — USE_NETWORK_VOLUME=true but missing on $_VOL_BASE:$MISSING" >&2
    echo "worker-comfyui: Attach the network volume with the PHIL Rapid-AIO GGUFs and retry." >&2
    echo "worker-comfyui: The volume was set up with this exact layout — re-run this if Pod went cold (VOL=$_VOL_BASE):" >&2
    echo "worker-comfyui:   mkdir -p \$_VOL_BASE/models/text_encoders \$_VOL_BASE/models/diffusion_models \$_VOL_BASE/models/vae \$_VOL_BASE/models/loras" >&2
    echo "worker-comfyui:   curl -L -C - -o \$_VOL_BASE/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf https://huggingface.co/Phil2Sat/Qwen-Image-Edit-Rapid-AIO-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct-abliterated/Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf" >&2
    echo "worker-comfyui:   curl -L -C - -o \$_VOL_BASE/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.mmproj-f16.gguf https://huggingface.co/Phil2Sat/Qwen-Image-Edit-Rapid-AIO-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct-abliterated/Qwen2.5-VL-7B-Instruct-abliterated.mmproj-f16.gguf" >&2
    echo "worker-comfyui:   curl -L -C - -o \$_VOL_BASE/models/diffusion_models/qwen-rapid-nsfw-v5.3-Q6_K.gguf https://huggingface.co/Phil2Sat/Qwen-Image-Edit-Rapid-AIO-GGUF/resolve/main/v53/qwen-rapid-nsfw-v5.3-Q6_K.gguf" >&2
    echo "worker-comfyui:   curl -L -C - -o \$_VOL_BASE/models/vae/qwen_image_vae.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors" >&2
    echo "worker-comfyui: See PLAN.md §3 or docs/network-volumes.md" >&2
    echo "worker-comfyui: Continuing anyway (ComfyUI will fail to find those models) ..." >&2
  else
    echo "worker-comfyui: FAST volume check OK — PHIL Rapid-AIO GGUFs present on $_VOL_BASE"
    ls -lh "$_VOL_BASE/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf" \
           "$_VOL_BASE/models/text_encoders/Qwen2.5-VL-7B-Instruct-abliterated.mmproj-f16.gguf" \
           "$_VOL_BASE/models/diffusion_models/qwen-rapid-nsfw-v5.3-Q6_K.gguf" \
           "$_VOL_BASE/models/vae/qwen_image_vae.safetensors"  2>&1 | sed 's/^/worker-comfyui:   /'
  fi
  # 1b) nodes_qwen patch check
  if grep -q "TextEncodeQwenImageEditPlus" /comfyui/comfy_extras/nodes_qwen.py 2>/dev/null; then
    echo "worker-comfyui: nodes_qwen.py check OK — TextEncodeQwenImageEditPlus present (Phr00t v2 patch)"
  else
    echo "worker-comfyui: FATAL — /comfyui/comfy_extras/nodes_qwen.py missing TextEncodeQwenImageEditPlus (patch not applied, build stale)" >&2
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