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

# --- AMD GPU auto-detection -------------------------------------------------------
# Detect the AMD GPU gfx target from the host using rocm-smi or rocminfo,
# then map it to the RDNA family and set the HSA_OVERRIDE_GFX_VERSION that
# ROCm needs for unsupported consumer GPUs.
#
# Override at any time:  make run mymodel.gguf HSA_GFX_VERSION=10.3.0

# 1. Try sysfs first (works even if rocm-smi is not installed on the host)
_SYSFS_GFX := $(shell cat /sys/class/kfd/kfd/topology/nodes/*/properties 2>/dev/null | awk '/gfx_target_version/ && $$2 != 0 {print $$2}' | head -n 1)
ifneq ($(_SYSFS_GFX),)
  _GFX_NUM := $(shell echo $(_SYSFS_GFX) | sed -E 's/0([0-9])/\1/g')
else
  # 2. Fallback to rocm-smi or rocminfo
  _GFX_RAW := $(shell \
    if command -v rocm-smi >/dev/null 2>&1; then \
      rocm-smi --showproductname 2>/dev/null | grep -oiE 'gfx[0-9a-f]+' | head -1; \
    elif command -v rocminfo >/dev/null 2>&1; then \
      rocminfo 2>/dev/null | grep -m1 -oiE 'gfx[0-9a-f]+' | head -1; \
    fi)
  _GFX_NUM := $(shell echo '$(_GFX_RAW)' | grep -oiE '[0-9a-f]+$$')
endif

# Extract prefix
_GFX_PREFIX := $(shell echo '$(_GFX_NUM)' | cut -c1-3)

# Map prefix -> override version
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

# --- ROCR_VISIBLE_DEVICES (A2) ------------------------------------------------
# Auto-select the first *discrete* GPU (index where rocm-smi reports a PCIe
# bus address, i.e. not an integrated / CPU-embedded node).
# Override: make run mymodel.gguf ROCR_VISIBLE_DEVICES=0
# Disable:  make run mymodel.gguf ROCR_VISIBLE_DEVICES=
ifndef ROCR_VISIBLE_DEVICES
  _ROCR_IDX := $(shell \
    if command -v rocm-smi >/dev/null 2>&1; then \
      rocm-smi --showbus 2>/dev/null \
        | awk '/GPU\[/{gpu=$$1} /Bus/{if($$NF ~ /^[0-9a-fA-F]{4}:/){print gpu; exit}}' \
        | grep -oE '[0-9]+' | head -1; \
    fi)
  ifneq ($(_ROCR_IDX),)
    _ROCR_ENV := --env ROCR_VISIBLE_DEVICES=$(_ROCR_IDX)
  else
    _ROCR_ENV :=
  endif
else
  ifneq ($(ROCR_VISIBLE_DEVICES),)
    _ROCR_ENV := --env ROCR_VISIBLE_DEVICES=$(ROCR_VISIBLE_DEVICES)
  else
    _ROCR_ENV :=
  endif
endif

# Convenience alias: inject any extra ROCm env vars at run time.
# e.g.  make run mymodel.gguf ROCM_ENV="--env AMD_SERIALIZE_KERNEL=3"
ROCM_ENV ?=

# --- Llama Server Knobs -------------------------------------------------------
# Layers to offload to GPU. Increase incrementally (16 → 24 → 32 … 99 = all)
N_GPU_LAYERS  ?= 99
# Context window (tokens)
N_CTX         ?= 4096

# CPU threads (D1) — auto-detect: leave 2 cores free for the OS.
# Override: make run mymodel.gguf THREADS=8
THREADS ?= $(shell nproc 2>/dev/null | awk '{n=$$1-2; print (n<1)?1:n}')

# Flash Attention (B2) — halves KV-cache VRAM; safe to leave on for RDNA 2+.
# Disable: make run mymodel.gguf FLASH_ATTN=0
FLASH_ATTN ?= 1

# KV cache quantization (B3) — store K and V tensors in q8_0 instead of f16.
# Halves KV VRAM with negligible quality impact.
# Set to f16 to disable: make run mymodel.gguf KV_CACHE_TYPE=f16
KV_CACHE_TYPE ?= q8_0

# Build flash-attention and KV-cache flags
# Use the long form "--flash-attn on" — bare "-fa" accepts an optional value
# so the parser would greedily consume the next flag (--cache-type-k) as it.
_FA_FLAG := --flash-attn off
_KV_FLAGS := --cache-type-k $(KV_CACHE_TYPE) --cache-type-v f16
ifeq ($(FLASH_ATTN),1)
  _FA_FLAG := --flash-attn on
  # V-cache quantization strictly requires Flash Attention in llama.cpp
  _KV_FLAGS := --cache-type-k $(KV_CACHE_TYPE) --cache-type-v $(KV_CACHE_TYPE)
endif

# --- Logging ------------------------------------------------------------------
ENABLE_FILE_LOGGING ?= false
LOG_DIR             ?= $(CURDIR)/llama-logs

# --- Server arguments ---------------------------------------------------------
# Override the whole string if you need full control; otherwise tune the vars above.
# Note: --host is intentionally omitted here; the image sets LLAMA_ARG_HOST=0.0.0.0
# by default. Adding --host would only produce a harmless warning.
EXTRA_ARGS ?= -ngl $(N_GPU_LAYERS) -c $(N_CTX) -t $(THREADS) $(_FA_FLAG) $(_KV_FLAGS)

# --- Container hardening flags (E1, E3) ---------------------------------------
# --security-opt seccomp=unconfined  lets ROCm make privileged syscalls that
#   the default seccomp profile blocks (fixes mysterious ROCm crashes).
# --ulimit memlock=-1                allows ROCm to lock GPU buffers in RAM.
_CONTAINER_OPTS := --security-opt seccomp=unconfined --ulimit memlock=-1

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
.PHONY: run download stop logs status check pull help gpu-info gpu-watch

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
	@if [ -n "$(_ROCR_ENV)" ]; then \
	  echo "⚙️   GPU selector: $(_ROCR_ENV)"; \
	fi
	@echo "🚀  Starting $(CONTAINER_NAME) [$(ENGINE)] → model: $(MODEL_FILE)"
	@if [ "$(ENABLE_FILE_LOGGING)" = "true" ]; then \
	  mkdir -p "$(LOG_DIR)"; \
	  echo "🛠️   Command being executed:"; \
	  (set -x; $(ENGINE) run -d --rm \
	    --name $(CONTAINER_NAME) \
	    -p $(PORT):8080 \
	    -v "$(MODELS_DIR):/models:ro" \
	    -v "$(LOG_DIR):/logs" \
	    $(DEVICES) \
	    $(_CONTAINER_OPTS) \
	    $(_HSA_ENV) \
	    $(_ROCR_ENV) \
	    $(ROCM_ENV) \
	    --entrypoint /bin/sh \
	    $(IMAGE) \
	    -c '/app/llama-server -m "/models/$(MODEL_FILE)" $(EXTRA_ARGS) 2>&1 | tee /logs/llama-server.log'); \
	  echo "✅  Server started. Logs → $(LOG_DIR)/llama-server.log  (make logs)"; \
	else \
	  echo "🛠️   Command being executed:"; \
	  (set -x; $(ENGINE) run -d --rm \
	    --name $(CONTAINER_NAME) \
	    -p $(PORT):8080 \
	    -v "$(MODELS_DIR):/models:ro" \
	    $(DEVICES) \
	    $(_CONTAINER_OPTS) \
	    $(_HSA_ENV) \
	    $(_ROCR_ENV) \
	    $(ROCM_ENV) \
	    $(IMAGE) \
	    -m "/models/$(MODEL_FILE)" $(EXTRA_ARGS)); \
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
# Show GPU detection results (useful for debugging).
gpu-info:
	@echo ""
	@echo "  🎮  AMD GPU Detection"
	@echo ""
	@if [ -n "$(_GFX_RAW)" ]; then \
	  echo "    Raw gfx target       : $(_GFX_RAW)"; \
	  echo "    RDNA generation      : $(_RDNA_GEN)"; \
	  echo "    HSA_OVERRIDE_GFX     : $(_HSA_OVERRIDE)"; \
	  echo "    Container HSA --env  : $(_HSA_ENV)"; \
	  echo "    Container ROCR --env : $(_ROCR_ENV)"; \
	else \
	  echo "    ⚠️  Could not detect GPU (rocm-smi / rocminfo not found or no AMD GPU)"; \
	  echo "    Install rocm-smi or rocminfo, or set: make run MODEL=x HSA_GFX_VERSION=10.3.0"; \
	fi
	@echo ""

# -----------------------------------------------------------------------------
# Live GPU utilisation — tails rocm-smi stats until Ctrl-C.
# Override GPU index:  make gpu-watch GPU_IDX=1
GPU_IDX ?= 0
gpu-watch:
	@echo "📊  Watching GPU $(GPU_IDX) stats (Ctrl-C to stop) …"
	@rocm-smi -d $(GPU_IDX) --showuse --showmemuse --showtemp --showpower --loop 1

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
	@echo "    make gpu-watch                       Live GPU utilisation (rocm-smi)"
	@echo "    make help                            Show this message"
	@echo ""
	@echo "  DOWNLOADING MODELS"
	@echo "    make download <repo> <file>          Via HuggingFace CLI (hf)"
	@echo "    make download URL=<url>              Via wget / curl"
	@echo ""
	@echo "  ROCm / GPU OVERRIDES"
	@echo "    GPU auto-detected via rocm-smi / rocminfo (RDNA 1/2/3/4 mapped automatically)"
	@echo "    Pin HSA version:   make run <model> HSA_GFX_VERSION=10.3.0"
	@echo "    Disable HSA:       make run <model> HSA_GFX_VERSION="
	@echo "    Pin GPU index:     make run <model> ROCR_VISIBLE_DEVICES=0"
	@echo "    Extra ROCm env:    make run <model> ROCM_ENV='--env AMD_SERIALIZE_KERNEL=3'"
	@echo ""
	@echo "  PERFORMANCE KNOBS  (current values)"
	@echo "    FLASH_ATTN        = $(FLASH_ATTN)   (1=on, 0=off)"
	@echo "    KV_CACHE_TYPE     = $(KV_CACHE_TYPE)  (q8_0 | q4_0 | f16)"
	@echo "    N_GPU_LAYERS      = $(N_GPU_LAYERS)"
	@echo "    N_CTX             = $(N_CTX)"
	@echo "    THREADS           = $(THREADS)  (auto: nproc-2)"
	@echo ""
	@echo "  VARIABLES  (current values)"
	@echo "    ENGINE            = $(ENGINE)"
	@echo "    IMAGE             = $(IMAGE)"
	@echo "    CONTAINER_NAME    = $(CONTAINER_NAME)"
	@echo "    PORT              = $(PORT)"
	@echo "    MODELS_DIR        = $(MODELS_DIR)"
	@echo "    DEVICES           = $(DEVICES)"
	@echo "    ENABLE_FILE_LOGGING = $(ENABLE_FILE_LOGGING)"
	@echo "    LOG_DIR           = $(LOG_DIR)"
	@echo "    EXTRA_ARGS        = $(EXTRA_ARGS)"
	@if [ -n "$(_GFX_RAW)" ]; then \
	  echo "    GPU (detected)    = $(_GFX_RAW) ($(_RDNA_GEN))"; \
	  echo "    HSA_OVERRIDE_GFX  = $(_HSA_OVERRIDE)  (auto)"; \
	  if [ -n "$(_ROCR_IDX)" ]; then \
	    echo "    ROCR_VISIBLE      = $(_ROCR_IDX)  (auto, discrete GPU)"; \
	  fi; \
	else \
	  echo "    GPU (detected)    = (none — rocm-smi/rocminfo not found)"; \
	fi
	@echo ""
