# Network Volumes & Model Paths

This document explains how to use RunPod **Network Volumes** with `worker-comfyui`, how model paths are resolved inside the container, and how to debug cases where models are not detected.

> **Scope**
>
> These instructions apply to **serverless endpoints** using this worker. Pods mount network volumes at `/workspace` by default, while serverless workers see them at `/runpod-volume`.

## Directory Mapping

For **serverless endpoints**:

- Network volume root is mounted at: `/runpod-volume`
- ComfyUI models are expected under: `/runpod-volume/models/...`

For **Pods**:

- Network volume root is mounted at: `/workspace`
- Equivalent ComfyUI model path: `/workspace/models/...`

If you use the S3-compatible API, the same paths map as:

- Serverless: `/runpod-volume/my-folder/file.txt`
- Pod: `/workspace/my-folder/file.txt`
- S3 API: `s3://<NETWORK_VOLUME_ID>/my-folder/file.txt`

## Expected Directory Structure

Models must be placed in the following structure on your network volume:

```text
/runpod-volume/
└── models/
    ├── checkpoints/      # Stable Diffusion checkpoints (.safetensors, .ckpt)
    ├── loras/            # LoRA files (.safetensors, .pt)
    ├── vae/              # VAE models (.safetensors, .pt)
    ├── clip/             # CLIP models (.safetensors, .pt)
    ├── clip_vision/      # CLIP Vision models
    ├── controlnet/       # ControlNet models (.safetensors, .pt)
    ├── embeddings/       # Textual inversion embeddings (.safetensors, .pt)
    ├── upscale_models/   # Upscaling models (.safetensors, .pt)
    ├── unet/             # UNet models
    ├── configs/          # Model configs (.yaml, .json)
    ├── text_encoders/    # GGUF text encoders — Qwen VL etc. (.gguf)
    └── diffusion_models/ # GGUF UNet/DiT — qwen-image-edit etc. (.gguf)
```

> **Note**
>
> Only create the subdirectories you actually need; empty or missing folders are fine.

## Supported File Extensions

ComfyUI only recognizes files with specific extensions when scanning model directories.

| Model Type       | Supported Extensions                        |
| ---------------- | ------------------------------------------- |
| Checkpoints      | `.safetensors`, `.ckpt`, `.pt`, `.pth`, `.bin` |
| LoRAs            | `.safetensors`, `.pt`                       |
| VAE              | `.safetensors`, `.pt`, `.bin`               |
| CLIP             | `.safetensors`, `.pt`, `.bin`               |
| ControlNet       | `.safetensors`, `.pt`, `.pth`, `.bin`       |
| Embeddings       | `.safetensors`, `.pt`, `.bin`               |
| Upscale Models   | `.safetensors`, `.pt`, `.pth`               |
| Text Encoders    | `.gguf`, `.safetensors`, `.bin`             |
| Diffusion Models | `.gguf`, `.safetensors`, `.bin`             |

Files with other extensions (for example `.txt`, `.zip`) are **ignored** by ComfyUI’s model discovery.

## Common Issues

- **Wrong root directory**
  - Models placed directly under `/runpod-volume/checkpoints/...` instead of `/runpod-volume/models/checkpoints/...`.
- **Incorrect extensions**
  - Files named without one of the supported extensions are skipped.
- **Empty directories**
  - No actual model files present in `models/checkpoints` (or other folders).
- **Volume not attached** ← the #1 cause of `unet_name: '...gguf' not in []` / `clip_name not in []`
  - Endpoint created without selecting a network volume under **Advanced → Select Network Volume**.
  - When this happens the GGUF loaders (`UnetLoaderGGUF`, `CLIPLoaderGGUF`) report **empty lists** (`not in []`) and validation 400s every request.
  - Look for `worker-comfyui: FATAL — /runpod-volume does not exist` in startup logs — that means the volume is truly not mounted.
  - Fix: **RunPod Console → Serverless → your endpoint → Manage → Edit → Advanced → Network Volume → select `qwen-fast-models` → Save**. Must be in the **same region** as the endpoint (CA/US-CA for this worker). Then scale workers to 0 and send a new request.
- **Volume attached but folder still empty / scanned as `found 0 files`**
  - The volume WAS populated via a Pod, but the Pod's volume was mounted at `/workspace` while this worker reads `/runpod-volume` — both point to the same data, so population script must use `/runpod-volume/models/...` regardless of mount hint.
  - Or population was interrupted (curl without `-C -` left a `.gguf` truncated to 0 B) — re-run the PLAN.md §3 populate block with `curl -L -C -`.
- **ComfyUI-Manager offline gotcha**
  - `src/start.sh` forces `comfy-manager-set-mode offline`. Installing GGUF nodes via Manager UI at runtime won't persist — they must be baked (Dockerfile's `ComfyUI-GGUF` step).

If any of the above is true, ComfyUI will silently fail to discover models from the network volume and `/prompt` will 400 with `prompt_outputs_failed_validation`.

## Debugging with `NETWORK_VOLUME_DEBUG`

The worker exposes an opt‑in debug mode controlled via the `NETWORK_VOLUME_DEBUG` environment variable.

### When to Use

Enable this when:

- Models on your network volume are not appearing in ComfyUI
- You suspect the directory structure or file extensions are wrong
- You want to quickly verify what the worker can actually see on `/runpod-volume`

### How to Enable

1. Go to your serverless **Endpoint → Manage → Edit**.
2. Under **Environment Variables**, add:

   - `NETWORK_VOLUME_DEBUG=true`

3. Save and wait for workers to restart (or scale to zero and back up).
4. Send any request to your endpoint (even a minimal one) to trigger the diagnostics.

### Reading the Diagnostics

When enabled, each request prints a detailed report to the worker logs, for example:

```text
======================================================================
NETWORK VOLUME DIAGNOSTICS (NETWORK_VOLUME_DEBUG=true)
======================================================================

[1] Checking extra_model_paths.yaml configuration...
    ✓ FOUND: /comfyui/extra_model_paths.yaml

[2] Checking network volume mount at /runpod-volume...
    ✓ MOUNTED: /runpod-volume

[3] Checking directory structure...
    ✓ FOUND: /runpod-volume/models

[4] Scanning model directories...

    checkpoints/:
      - my-model.safetensors (6.5 GB)

    loras/:
      - style-lora.safetensors (144.2 MB)

[5] Summary
    ✓ Models found on network volume!
======================================================================
```

If there is a problem, the diagnostics will instead highlight it, for example:

- Missing `models/` directory
- No valid model files in any subdirectory
- Files present but ignored due to wrong extensions

### Disabling Debug Mode

Once you have resolved your issue, disable diagnostics to keep logs clean:

- Remove the `NETWORK_VOLUME_DEBUG` environment variable, **or**
- Set `NETWORK_VOLUME_DEBUG=false`

This returns the worker to normal behavior without extra log noise.


