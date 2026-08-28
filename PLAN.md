# darkcoal-qwen-fast — Silver Platter Plan

You asked for a "just copy-paste / just push" plan. This is it. Two separate tasks:

- **Task A (once, ~10 min hands-on):** Create + populate the Network Volume in RunPod — this is what kills the 10-min cold start.
- **Task B (one push, ~3 min build):** `darkcoal-qwen-fast` image that uses the volume (no 20GB GGUF bake).

> **darkcoal-qwen (current) stays untouched and still works.** `fast` is a separate repo/image (`ghcr.io/alfa-jim/darkcoal-qwen-fast:latest`). You can run both side-by-side and switch the endpoint's image with no downtime.

---

## 0) What you will have at the end

| Item | Before | After |
|------|--------|-------|
| Image `darkcoal-qwen` (baked GGUFs) | ~30 GB, 12-min build, 10-min cold start | stays, still works |
| Image `darkcoal-qwen-fast` (volume-native) | — | **~5 GB, ~3-min build, ~90s cold start** |
| Network Volume `qwen-fast-models` | — | 50 GB, ~$5/mo, holds 3 raw `.gguf` + VAE + LoRA |

---

## 1) Create the Network Volume (RunPod Dashboard, 2 min — point & click)

1. Open **RunPod → Storage → Network Volumes → Create Network Volume**.
2. Settings:
   - **Name:** `qwen-fast-models`
   - **Region:** **CA** (your workers are in California → pick the **CA / US-CA** option; that's US West. The volume **must** be in the same region+datacenter family as the endpoint or it won't attach).
   - **Size:** `50 GB` (3 GGUFs 21 GB + VAE/LoRA + headroom).
3. Click **Create**. Note the **Volume ID** (looks like `a1b2c3...`).

---

## 2) Create a temporary Pod to fill the volume (3 min — click)

1. **Pods → Deploy Pod**.
2. **GPU:** pick the cheapest (e.g. `RTX 4090` or `A40`, 1× — doesn't matter, pod BB disk is separate).
3. **Volume:** under **Network Volume**, select `qwen-fast-models`. It will mount at **`/runpod-volume`** (pods show it as `/runpod-volume`, serverless sees same path). *(If Pod UI says `/workspace`, both `/runpod-volume` and `/workspace` point to same data — we use `/runpod-volume`.)*
4. **Template:** `RunPod Pytorch 2.x` (any linux template with `curl` + `bash` is fine).
5. **Container Disk:** 20 GB is enough (we don't store long-term in container).
6. Deploy → wait until **Running** → **Connect → Start JupyterLab** or **SSH**.

---

## 3) Populate the volume (copy-paste ONE block into Pod terminal, ~8 min once)

Open a terminal in the Pod (JupyterLab → Terminal, or SSH). **Paste this entire block and hit Enter:**

```bash
set -eux
# --- darkcoal-qwen-fast volume populate — raw uncensored GGUFs, no unpacking ---
# Must match src/extra_model_paths.yaml directories.

mkdir -p /runpod-volume/models/text_encoders \
         /runpod-volume/models/diffusion_models \
         /runpod-volume/models/vae \
         /runpod-volume/models/loras

echo "== volume before =="; df -h /runpod-volume; du -sh /runpod-volume/models/* 2>&1 | head -20 || true

# VAE 254MB + anime LoRA (~150MB) — tiny, but volume is source of truth for fast image.
# If you skip these, fast still works (image has them baked), but volume copy is nice.
[ -f /runpod-volume/models/vae/qwen_image_vae.safetensors ] || \
  curl -L --retry 5 --retry-delay 10 --retry-all-errors --progress-bar \
  -o /runpod-volume/models/vae/qwen_image_vae.safetensors \
  https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors

[ -f /runpod-volume/models/loras/qwen-anime-irl.safetensors ] || \
  curl -L --retry 5 --retry-delay 10 --retry-all-errors --progress-bar \
  -o /runpod-volume/models/loras/qwen-anime-irl.safetensors \
  https://huggingface.co/flymy-ai/qwen-image-anime-irl-lora/resolve/main/flymy_anime_irl.safetensors

# ── The 3 uncensored heavies — raw .gguf, straight from HF, no unpacking ──
# 1/3 text encoder q4_0 (4.13GB)
[ -f /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf ] || \
  curl -L --retry 5 --retry-delay 10 --retry-all-errors --progress-bar \
  -o /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf \
  https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf

# 2/3 mmproj projector (1.35GB) — MUST sit alongside the encoder and MUST have "mmproj" in name
[ -f /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf ] || \
  curl -L --retry 5 --retry-delay 10 --retry-all-errors --progress-bar \
  -o /runpod-volume/models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf \
  https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf

# 3/3 diffusion Q6_K (15.6GB)
[ -f /runpod-volume/models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf ] || \
  curl -L --retry 5 --retry-delay 10 --retry-all-errors --progress-bar \
  -o /runpod-volume/models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf \
  https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf

echo "== volume after =="; ls -lh /runpod-volume/models/text_encoders/ /runpod-volume/models/diffusion_models/ /runpod-volume/models/vae/ 2>&1
du -sh /runpod-volume/models/* 2>&1
echo "== done — you can terminate this Pod =="
```

Wait until you see `done`. Spot-check:

```bash
ls -lh /runpod-volume/models/text_encoders/*.gguf /runpod-volume/models/diffusion_models/*.gguf | awk '{print $9, $5}'
# expect:
# Qwen2.5-VL-7B-Instruct-q4_0.gguf            4.1G
# Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf      1.4G
# qwen-image-edit-2511-uncensored-Q6_K.gguf   15.6G
```

If any line is missing, re-run the block — it's idempotent (`[ -f ] || curl` skips already-present files).

**Then terminate the Pod** (Pods → Stop/Terminate). The volume persists.

---

## 4) Attach the volume to the serverless endpoint (1 min — click)

1. **Serverless → Endpoints → your Qwen endpoint → Manage → Edit Endpoint** (or create new endpoint for `fast`).
2. **Container Image:** keep `ghcr.io/alfa-jim/darkcoal-qwen:latest` for now (or switch to `.../darkcoal-qwen-fast:latest` after Task B builds — see below). Both work with the volume attached; `fast` is just leaner.
3. **Advanced → Network Volume → Select** `qwen-fast-models`.
4. **Save.**

Scale to 0 to force a cold start test: **Endpoint → Workers → Min Workers 0 → Save → send one request** — you should see `FAST volume check OK` in worker logs (instead of 10m download).

Diagnostics (optional): set env `NETWORK_VOLUME_DEBUG=true` on the endpoint, send any request, read logs — it will list `text_encoders/`, `diffusion_models/`, `vae/` contents.

---

## 5) Push `darkcoal-qwen-fast` (separate repo, fast build)

This folder (`darkcoal-qwen-fast/`) is already patched to be volume-native:

- `Dockerfile` skips the 21 GB GGUF bake when `USE_NETWORK_VOLUME=true` (default) — only VAE+LoRA baked (`~5 GB` image, `~3 min` build).
- `src/start.sh` fails loudly if volume missing (`FAST volume check OK` / `FATAL ... missing on /runpod-volume`).
- `src/extra_model_paths.yaml` unchanged — already maps `/runpod-volume/models/text_encoders/` etc.
- `playground.html` timeout bumped to **10 min** (was 5) so long img2img + cold start don't cut off.
- `test_input_edit.json` already fixed to `TextEncodeQwenImageEdit` (plus mmproj).

### One-time: create the GitHub repo

Go to **github.com → New repository**:

- **Owner:** `Alfa-jim`
- **Name:** `darkcoal-qwen-fast`
- **Visibility:** **Public** (so GHCR pulls work; you can keep code public, models stay private on volume)
- **Don't** initialize with README — we push this folder.
- Create repo (leave empty).

### Push (copy-paste from this folder):

```bash
cd "C:\Users\dutap\OneDrive\Desktop\DSH workspace\darkcoal-qwen-fast"
git remote add origin https://github.com/Alfa-jim/darkcoal-qwen-fast.git
git add -A
git commit -m "feat(fast): network-volume-native qwen (no GGUF bake, 10m playground timeout)"
git push -u origin main
```

That's it — pushing to `main` **immediately triggers GHCR build** (`.github/workflows/build.yml` `on: push: branches: [main]`). Watch it:

- Go to **GitHub → Alfa-jim/darkcoal-qwen-fast → Actions**.
- Build `Build and Push to GHCR (qwen-fast)` should finish in ~3 min (not 12) → tags `ghcr.io/alfa-jim/darkcoal-qwen-fast:latest` and `:qwen-image-edit`.

Make the GHCR package public once (first push): repo **Packages → darkcoal-qwen-fast → Package settings → Change visibility → Public**, or add GHCR creds to the RunPod template.

Then point your endpoint at `ghcr.io/alfa-jim/darkcoal-qwen-fast:latest` and redeploy.

---

## 6) Quick rollback (if anything goes wrong)

- Detach the network volume from the endpoint (Edit → Network Volume → None) — endpoint falls back to baked `darkcoal-qwen:latest` with no config change.
- Point image back to `ghcr.io/alfa-jim/darkcoal-qwen:latest`.

Original repo is untouched.

---

## 7) What was *not* changed in darkcoal-qwen

Per your "don't do any changes to the codebase yet" for `darkcoal-qwen`: its `Dockerfile`/`test_input_edit.json` (mmproj fix) was already pushed as `e31b442` earlier — that's the bake fix. `darkcoal-qwen-fast` is the new volume copy; all edits above are confined there.

---

## 8) End-to-end test (after volume + fast image are live)

```bash
# txt2img (no input image):
curl -s -X POST -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
  -d @test_input.json \
  https://api.runpod.ai/v2/<endpoint-id>/runsync | jq '.output.images | length'

# img2img (uses mmproj — the bug you hit):
curl -s -X POST -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
  -d @test_input_edit.json \
  https://api.runpod.ai/v2/<endpoint-id>/runsync | jq '.output.images | length, .output.errors'
```

Or use `playground.html` in this folder (mode `img2img`, drop a `ref.png`, Generate).

Logs should show `FAST volume check OK — uncensored GGUFs present on /runpod-volume` and **no** `Can't find mmproj` warning.
