# =============================================================================
# making-llamas-rock — run llama-server (ROCm) via Podman/Docker
# =============================================================================

# --- Core Variables ----------------------------------------------------------
PORT          ?= 8080
MODELS_DIR    ?= $(CURDIR)
IMAGE         ?= ghcr.io/ggml-org/llama.cpp:server-rocm
CONTAINER_NAME?= llama-server
ENGINE        ?= podman

# --- Hardware / Devices -------------------------------------------------------
# Default: AMD ROCm. Nvidia override example: DEVICES="--gpus all"
DEVICES       ?= --device /dev/kfd --device /dev/dri

# --- GPU auto-detection -------------------------------------------------------
# Detect the AMD GPU gfx target from the host using rocm-smi, rocminfo, or
# sysfs (in that priority order), then map it to the RDNA family and set the
# HSA_OVERRIDE_GFX_VERSION that ROCm needs for unsupported consumer GPUs.
#
# Override at any time:  make run mymodel.gguf HSA_GFX_VERSION=10.3.0
#                        make run mymodel.gguf ROCM_ENV=   (disable override)
#
# Detection tries:
#   1. rocm-smi --showproductname  → extracts "gfxNNNN" token
#   2. rocminfo                    → first "Name: gfxNNNN" line
#   3. /sys/class/drm/*/device/product_name (fallback, name-based)

# Step 1 – raw gfx string (e.g. "gfx1030", "gfx1100", …)
_GFX_RAW := $(shell \
  if command -v rocm-smi >/dev/null 2>&1; then \
    rocm-smi --showproductname 2>/dev/null \
      | grep -oiE 'gfx[0-9a-f]+' | head -1; \
  elif command -v rocminfo >/dev/null 2>&1; then \
    rocminfo 2>/dev/null \
      | grep -m1 -oiE 'gfx[0-9a-f]+' | head -1; \
  fi)

# Step 2 – numeric part only (e.g. "1030", "1100")
_GFX_NUM := $(shell echo '$(_GFX_RAW)' | grep -oiE '[0-9a-f]+$$')

# Step 3 – leading three hex digits decide the RDNA generation
#   gfx101x → RDNA 1 → 10.1.0
#   gfx103x → RDNA 2 → 10.3.0
#   gfx110x → RDNA 3 → 11.0.0
#   gfx111x → RDNA 3 → 11.0.0
#   gfx115x → RDNA 3.5 (APU) → 11.5.0   (treated as 11.0.0 by ROCm)
#   gfx120x → RDNA 4 → 12.0.0
_GFX_PREFIX := $(shell echo '$(_GFX_NUM)' | cut -c1-3)

# Map prefix → override version string
ifeq ($(_GFX_PREFIX),101)
  _RDNA_GEN     := RDNA 1
  _HSA_OVERRIDE := 10.1.0
else ifeq ($(_GFX_PREFIX),103)
  _RDNA_GEN     := RDNA 2
  _HSA_OVERRIDE := 10.3.0
else ifeq ($(_GFX_PREFIX),110)
  _RDNA_GEN     := RDNA 3
  _HSA_OVERRIDE := 11.0.0
else ifeq ($(_GFX_PREFIX),111)
  _RDNA_GEN     := RDNA 3
  _HSA_OVERRIDE := 11.0.0
else ifeq ($(_GFX_PREFIX),115)
  _RDNA_GEN     := RDNA 3.5 (APU)
  _HSA_OVERRIDE := 11.0.0
else ifeq ($(_GFX_PREFIX),120)
  _RDNA_GEN     := RDNA 4
  _HSA_OVERRIDE := 12.0.0
else
  _RDNA_GEN     := unknown
  _HSA_OVERRIDE :=
endif

# Build the --env fragment (empty string = no override injected)
ifndef HSA_GFX_VERSION
  # User did not pin a version — use what we auto-detected
  ifneq ($(_HSA_OVERRIDE),)
    _HSA_ENV := --env HSA_OVERRIDE_GFX_VERSION=$(_HSA_OVERRIDE)
  else
    _HSA_ENV :=
  endif
else
  # User pinned a version explicitly (including empty string to disable)
  ifneq ($(HSA_GFX_VERSION),)
    _HSA_ENV := --env HSA_OVERRIDE_GFX_VERSION=$(HSA_GFX_VERSION)
  else
    _HSA_ENV :=
  endif
endif

# Convenience alias so the recipe can also accept ROCM_ENV=… to inject any
# extra ROCm env vars (e.g. ROCM_ENV="--env AMD_SERIALIZE_KERNEL=3")
ROCM_ENV ?=

# --- Llama Server Knobs -------------------------------------------------------
# Layers to offload to GPU. Increase incrementally (16 → 24 → 32 … 99 = all)
N_GPU_LAYERS  ?= 99
# Context window (tokens)
N_CTX         ?= 4096
# CPU threads — leave 2-4 cores free for the OS (e.g. 8-core Ryzen 7735HS → 6)
THREADS       ?= 6

# --- Logging ------------------------------------------------------------------
ENABLE_FILE_LOGGING ?= false
LOG_DIR             ?= $(CURDIR)/llama-logs

# --- Server arguments ---------------------------------------------------------
# Override the whole string if you need full control; otherwise tune the vars above.
EXTRA_ARGS ?= --host 0.0.0.0 -ngl $(N_GPU_LAYERS) -c $(N_CTX) -t $(THREADS)

# =============================================================================
# Argument parsing
#   make run <model.gguf>          → MODEL_FILE=<model.gguf>
#   make run MODEL=<model.gguf>    → MODEL_FILE=<model.gguf>  (classic override)
#   make download <repo> <file>    → DOWNLOAD_ARGS set
# =============================================================================
ifeq (run,$(firstword $(MAKECMDGOALS)))
  _RUN_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(if $(_RUN_ARGS),$(eval $(_RUN_ARGS):;@:))
endif

ifeq (download,$(firstword $(MAKECMDGOALS)))
  DOWNLOAD_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(if $(DOWNLOAD_ARGS),$(foreach a,$(DOWNLOAD_ARGS),$(eval $(a):;@:)))
endif

MODEL_FILE := $(or $(_RUN_ARGS),$(MODEL))

# =============================================================================
.PHONY: run download stop logs status check pull help gpu-info

# -----------------------------------------------------------------------------
run: stop
	@[ -n "$(MODEL_FILE)" ] || { \
	  echo "❌  No model specified."; \
	  echo "    make run <model.gguf>   or   make run MODEL=<model.gguf>"; \
	  exit 1; }
	@[ -f "$(MODELS_DIR)/$(MODEL_FILE)" ] || { \
	  echo "❌  Model not found: $(MODELS_DIR)/$(MODEL_FILE)"; \
	  exit 1; }
	@if [ -n "$(_GFX_RAW)" ]; then \
	  echo "🎮  GPU detected: $(_GFX_RAW) ($(_RDNA_GEN))"; \
	fi
	@if [ -n "$(_HSA_ENV)" ]; then \
	  echo "⚙️   ROCm env: $(_HSA_ENV)"; \
	fi
	@echo "🚀  Starting $(CONTAINER_NAME) [$(ENGINE)] → model: $(MODEL_FILE)"
	@if [ "$(ENABLE_FILE_LOGGING)" = "true" ]; then \
	  mkdir -p "$(LOG_DIR)"; \
	  $(ENGINE) run -d \
	    --name $(CONTAINER_NAME) \
	    -p $(PORT):8080 \
	    -v "$(MODELS_DIR):/models" \
	    -v "$(LOG_DIR):/logs" \
	    $(DEVICES) \
	    $(_HSA_ENV) \
	    $(ROCM_ENV) \
	    --entrypoint /bin/sh \
	    $(IMAGE) \
	    -c '/app/llama-server -m "/models/$(MODEL_FILE)" $(EXTRA_ARGS) 2>&1 | tee /logs/llama-server.log'; \
	  echo "✅  Server started. Logs → $(LOG_DIR)/llama-server.log  (make logs)"; \
	else \
	  $(ENGINE) run -d \
	    --name $(CONTAINER_NAME) \
	    -p $(PORT):8080 \
	    -v "$(MODELS_DIR):/models" \
	    $(DEVICES) \
	    $(_HSA_ENV) \
	    $(ROCM_ENV) \
	    $(IMAGE) \
	    -m "/models/$(MODEL_FILE)" $(EXTRA_ARGS); \
	  echo "✅  Server started on :$(PORT)  (make logs | make check)"; \
	fi

# -----------------------------------------------------------------------------
download:
	@if [ -n "$(URL)" ]; then \
	  echo "⬇️   Downloading $(URL) ..."; \
	  if command -v wget >/dev/null 2>&1; then \
	    wget -c "$(URL)" -P "$(MODELS_DIR)"; \
	  else \
	    curl -L -C - -o "$(MODELS_DIR)/$$(basename '$(URL)')" "$(URL)"; \
	  fi; \
	  echo "✅  Saved to $(MODELS_DIR)"; \
	elif [ -n "$(DOWNLOAD_ARGS)" ]; then \
	  echo "⬇️   HuggingFace: hf download $(DOWNLOAD_ARGS)"; \
	  hf download $(DOWNLOAD_ARGS) --local-dir "$(MODELS_DIR)"; \
	  echo "✅  Saved to $(MODELS_DIR)"; \
	else \
	  echo "❌  Nothing to download. Examples:"; \
	  echo "    make download TheBloke/Llama-2-7B-Chat-GGUF llama-2-7b-chat.Q4_K_M.gguf"; \
	  echo "    make download URL=https://example.com/model.gguf"; \
	  exit 1; \
	fi

# -----------------------------------------------------------------------------
stop:
	@$(ENGINE) rm -f $(CONTAINER_NAME) 2>/dev/null \
	  && echo "🛑  Stopped $(CONTAINER_NAME)" \
	  || true

# -----------------------------------------------------------------------------
status:
	@$(ENGINE) ps --filter name=^$(CONTAINER_NAME)$

# -----------------------------------------------------------------------------
logs:
	@$(ENGINE) logs -f $(CONTAINER_NAME)

# -----------------------------------------------------------------------------
# Hit the /health endpoint — useful to confirm the server is ready.
check:
	@echo "🔍  GET http://localhost:$(PORT)/health"
	@curl -sf http://localhost:$(PORT)/health | cat \
	  || echo "❌  Server not responding on :$(PORT)"

# -----------------------------------------------------------------------------
# Show GPU detection results (useful for debugging)
gpu-info:
	@echo ""
	@echo "  🎮  AMD GPU Detection"
	@echo ""
	@if [ -n "$(_GFX_RAW)" ]; then \
	  echo "    Raw gfx target  : $(_GFX_RAW)"; \
	  echo "    RDNA generation : $(_RDNA_GEN)"; \
	  echo "    HSA_OVERRIDE    : $(_HSA_OVERRIDE)"; \
	  echo "    Container --env : $(_HSA_ENV)"; \
	else \
	  echo "    ⚠️  Could not detect GPU (rocm-smi / rocminfo not found or no AMD GPU)"; \
	  echo "    Install rocm-smi or rocminfo, or set: make run MODEL=x HSA_GFX_VERSION=10.3.0"; \
	fi
	@echo ""

# -----------------------------------------------------------------------------
# Pull the latest image without restarting a running server.
pull:
	@echo "📦  Pulling $(IMAGE) ..."
	@$(ENGINE) pull $(IMAGE)
	@echo "✅  Image up to date. Run 'make stop && make run <model>' to use it."

# -----------------------------------------------------------------------------
help:
	@echo ""
	@echo "  🦙  making-llamas-rock — llama.cpp ROCm server"
	@echo ""
	@echo "  USAGE"
	@echo "    make run <model.gguf>               Start server with a local model"
	@echo "    make run MODEL=<model.gguf>          (alternative syntax)"
	@echo "    make stop                            Stop + remove the container"
	@echo "    make status                          Show container status"
	@echo "    make logs                            Stream server logs"
	@echo "    make check                           GET /health to verify readiness"
	@echo "    make pull                            Pull the latest server image"
	@echo "    make gpu-info                        Show detected GPU / ROCm env"
	@echo "    make help                            Show this message"
	@echo ""
	@echo "  DOWNLOADING MODELS"
	@echo "    make download <repo> <file>          Via HuggingFace CLI (hf)"
	@echo "    make download URL=<url>              Via wget / curl"
	@echo ""
	@echo "  ROCm GPU OVERRIDE"
	@echo "    GPU auto-detected via rocm-smi / rocminfo (RDNA 1/2/3/4 mapped automatically)"
	@echo "    Pin manually:  make run <model> HSA_GFX_VERSION=10.3.0"
	@echo "    Disable:       make run <model> HSA_GFX_VERSION="
	@echo "    Extra env:     make run <model> ROCM_ENV='--env AMD_SERIALIZE_KERNEL=3'"
	@echo ""
	@echo "  VARIABLES  (current values)"
	@echo "    ENGINE            = $(ENGINE)"
	@echo "    IMAGE             = $(IMAGE)"
	@echo "    CONTAINER_NAME    = $(CONTAINER_NAME)"
	@echo "    PORT              = $(PORT)"
	@echo "    MODELS_DIR        = $(MODELS_DIR)"
	@echo "    DEVICES           = $(DEVICES)"
	@echo "    N_GPU_LAYERS      = $(N_GPU_LAYERS)"
	@echo "    N_CTX             = $(N_CTX)"
	@echo "    THREADS           = $(THREADS)"
	@echo "    ENABLE_FILE_LOGGING = $(ENABLE_FILE_LOGGING)"
	@echo "    LOG_DIR           = $(LOG_DIR)"
	@echo "    EXTRA_ARGS        = $(EXTRA_ARGS)"
	@if [ -n "$(_GFX_RAW)" ]; then \
	  echo "    GPU (detected)    = $(_GFX_RAW) ($(_RDNA_GEN))"; \
	  echo "    HSA_OVERRIDE_GFX  = $(_HSA_OVERRIDE)  (auto)"; \
	else \
	  echo "    GPU (detected)    = (none — rocm-smi/rocminfo not found)"; \
	fi
	@echo ""
