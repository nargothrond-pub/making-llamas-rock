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
.PHONY: run download stop logs status check pull help

# -----------------------------------------------------------------------------
run: stop
	@[ -n "$(MODEL_FILE)" ] || { \
	  echo "❌  No model specified."; \
	  echo "    make run <model.gguf>   or   make run MODEL=<model.gguf>"; \
	  exit 1; }
	@[ -f "$(MODELS_DIR)/$(MODEL_FILE)" ] || { \
	  echo "❌  Model not found: $(MODELS_DIR)/$(MODEL_FILE)"; \
	  exit 1; }
	@echo "🚀  Starting $(CONTAINER_NAME) [$(ENGINE)] → model: $(MODEL_FILE)"
	@if [ "$(ENABLE_FILE_LOGGING)" = "true" ]; then \
	  mkdir -p "$(LOG_DIR)"; \
	  $(ENGINE) run -d \
	    --name $(CONTAINER_NAME) \
	    -p $(PORT):8080 \
	    -v "$(MODELS_DIR):/models" \
	    -v "$(LOG_DIR):/logs" \
	    $(DEVICES) \
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
	@echo "    make help                            Show this message"
	@echo ""
	@echo "  DOWNLOADING MODELS"
	@echo "    make download <repo> <file>          Via HuggingFace CLI (hf)"
	@echo "    make download URL=<url>              Via wget / curl"
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
	@echo ""
