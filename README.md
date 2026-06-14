# 🦙 Making Llamas Rock!

![Llamas Rocking](./making-llamas-rock.jpeg)


A streamlined, optimized, and zero-headache `Makefile` for downloading and running local Large Language Models (LLMs) using `llama.cpp` and `podman`. 

Currently configured out-of-the-box for **AMD GPUs (ROCm)**, but easily adaptable for NVIDIA or CPU-only setups.

## ✨ Features
- **Effortless Downloads:** Fetch `.gguf` models directly from Hugging Face or via direct URLs using `wget`/`curl` fallback.
- **Dynamic Argument Parsing:** Run commands naturally like `make run my_model.gguf` without dealing with messy environment variable syntax.
- **Hardware Optimized:** Auto-detects CPU thread count (`nproc-2`), maximizes GPU layer offloading, and hardens the container with `seccomp=unconfined` and `memlock=-1` for stable ROCm operation.
- **Automatic GPU Detection:** Detects your AMD GPU via `rocm-smi` or `rocminfo`, sets the correct `HSA_OVERRIDE_GFX_VERSION` for RDNA 1/2/3/3.5/4 cards, and selects the discrete GPU index automatically via `ROCR_VISIBLE_DEVICES` — no manual tweaking needed.
- **VRAM-Efficient Defaults:** Flash Attention and KV-cache quantization (`q8_0`) are enabled by default to halve KV-cache VRAM usage with negligible quality impact.
- **Persistent Logging:** Container logs can be optionally piped to a local `llama-logs/llama-server.log` file while preserving standard terminal access.

## 📋 Prerequisites
- Linux Environment
- [Podman](https://podman.io/) installed
- [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli) (`hf`) installed for downloading from Hugging Face repositories.
- An AMD GPU with ROCm drivers installed (if using the default image).

## 🚀 Quick Start

### 1. Download a Model
You can download models straight from Hugging Face by providing the repository ID and the exact filename:
```bash
# Download via Hugging Face CLI
make download TheBloke/Llama-2-7B-Chat-GGUF llama-2-7b-chat.Q4_K_M.gguf

# OR Download via direct URL (uses wget if available, falls back to curl)
make download URL=https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.1-GGUF/resolve/main/mistral-7b-instruct-v0.1.Q4_K_M.gguf
```

### 2. Run the Model
Start the server and automatically mount the model into the container (read-only). Any existing llama-server container will be stopped and removed first.
```bash
make run llama-2-7b-chat.Q4_K_M.gguf
```
The GPU is auto-detected on startup — you'll see the detected target, HSA override, and GPU index applied (if any).

### 3. Check Logs
Watch the server generate responses or debug loading times:
```bash
make logs
```
*(If you enabled file logging, logs are also saved to `./llama-logs/llama-server.log`)*

### 4. Stop the Server
```bash
make stop
```

### 5. Check Server Status
Verify that the container is running or hit the `/health` endpoint to ensure the model is ready:
```bash
make status  # Shows container status
make check   # Tests the /health endpoint
```

### 6. Inspect GPU Detection
Shows the detected GFX target, RDNA generation, and the `HSA_OVERRIDE_GFX_VERSION` / `ROCR_VISIBLE_DEVICES` values that will be injected into the container:
```bash
make gpu-info
```

### 7. Watch Live GPU Utilisation
Streams GPU usage, memory, temperature, and power in a live loop (Ctrl-C to stop):
```bash
make gpu-watch          # Watch GPU 0 (default)
make gpu-watch GPU_IDX=1  # Watch a specific GPU index
```

### 8. Update the Server
Easily fetch the latest `llama.cpp` image without disrupting an active session:
```bash
make pull
```

---

## ⚙️ Tuning & Configuration

You can permanently change variables inside the `Makefile` or pass them dynamically when running a command.

```bash
N_GPU_LAYERS=24 FLASH_ATTN=0 make run model.gguf
```

### Available Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `ENGINE` | `podman` | The container runtime engine (e.g., `podman` or `docker`). |
| `IMAGE` | `ghcr.io/ggml-org/llama.cpp:server-rocm` | The llama.cpp server container image. |
| `DEVICES` | `--device /dev/kfd --device /dev/dri` | Hardware acceleration arguments passed to the container. |
| `PORT` | `8080` | The port exposed to your host machine. |
| `CONTAINER_NAME` | `llama-server` | Name of the container. |
| `MODELS_DIR` | `$(CURDIR)` | The directory where models are downloaded and read from (mounted read-only). |
| `N_GPU_LAYERS` | `99` | Number of layers to offload to the GPU. Keep at 99 for full offload, or lower it if you face VRAM pressure. |
| `N_CTX` | `4096` | Context window size. Increase for larger document processing (requires more RAM/VRAM). |
| `THREADS` | `nproc-2` (auto) | CPU threads allocated to model execution. Auto-detected as total cores minus 2. |
| `FLASH_ATTN` | `1` | Enable Flash Attention (`1`) or disable (`0`). Halves KV-cache VRAM on RDNA 2+. |
| `KV_CACHE_TYPE` | `q8_0` | KV-cache quantization type (`q8_0`, `q4_0`, or `f16`). Halves KV VRAM with negligible quality impact. |
| `EXTRA_ARGS` | *(derived from vars above)* | Full server argument string. Override for complete control. |
| `ENABLE_FILE_LOGGING` | `false` | Set to `true` to pipe server output to a text file. |
| `LOG_DIR` | `$(CURDIR)/llama-logs` | The directory where log files are stored. |

---

## 🎮 AMD GPU Auto-Detection

The Makefile automatically detects your AMD GPU using `rocm-smi` or `rocminfo` (in that order) and maps it to the correct `HSA_OVERRIDE_GFX_VERSION` — which is required for many consumer AMD GPUs not officially supported by ROCm.

It also auto-selects the first discrete GPU index and sets `ROCR_VISIBLE_DEVICES` accordingly, preventing ROCm from accidentally using an integrated GPU.

| RDNA Generation | GFX Target | HSA Override |
| :--- | :--- | :--- |
| RDNA 1 | gfx101x | `10.1.0` |
| RDNA 2 | gfx103x | `10.3.0` |
| RDNA 3 | gfx110x / gfx111x | `11.0.0` |
| RDNA 3.5 (APU) | gfx115x | `11.0.0` |
| RDNA 4 | gfx120x | `12.0.0` |

You can inspect what was detected with:
```bash
make gpu-info
```

### Overriding GPU Detection

```bash
# Pin a specific HSA version
make run model.gguf HSA_GFX_VERSION=10.3.0

# Disable the HSA override entirely
make run model.gguf HSA_GFX_VERSION=

# Pin a specific GPU index for ROCR_VISIBLE_DEVICES
make run model.gguf ROCR_VISIBLE_DEVICES=0

# Inject extra ROCm environment variables
make run model.gguf ROCM_ENV='--env AMD_SERIALIZE_KERNEL=3'
```

---

## 🛠️ Switching to NVIDIA (CUDA)
If you want to run this on an NVIDIA GPU, simply override the `IMAGE` and `DEVICES` variables (and `ENGINE` if using Docker):

```bash
ENGINE=docker DEVICES="--gpus all" IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda make run model.gguf
```

Or change them permanently inside the `Makefile`:
```makefile
ENGINE ?= docker
DEVICES ?= --gpus all
IMAGE ?= ghcr.io/ggml-org/llama.cpp:server-cuda
```

---

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details. Feel free to use it, tweak it, and share it!
