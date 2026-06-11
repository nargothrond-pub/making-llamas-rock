# Variables
PORT ?= 8080
MODELS_DIR ?= $(CURDIR)
IMAGE ?= ghcr.io/ggml-org/llama.cpp:server-rocm
CONTAINER_NAME ?= llama-server

# --- Llama Server Optimizations ---
# GPU Offload: Layers to offload to iGPU (Test incrementally: 16, 24, 32... 99 for full)
N_GPU_LAYERS ?= 99
# Context window size
N_CTX ?= 4096
# CPU Threads: Leave 2-4 physical cores free for OS/agents (Ryzen 7 7735HS has 8 cores -> use 6)
THREADS ?= 6
# File Logging
ENABLE_FILE_LOGGING ?= false
LOG_DIR ?= $(CURDIR)/llama-logs

EXTRA_ARGS ?= --host 0.0.0.0 -ngl $(N_GPU_LAYERS) -c $(N_CTX) -t $(THREADS)

# Extract arguments for "make run <model>" and "make download <args>"
ifeq (run,$(firstword $(MAKECMDGOALS)))
  RUN_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
endif

ifeq (download,$(firstword $(MAKECMDGOALS)))
  DOWNLOAD_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
endif

.PHONY: run download stop logs help

MODEL_FILE := $(if $(RUN_ARGS),$(RUN_ARGS),$(MODEL))

run: stop
	@if [ -z "$(MODEL_FILE)" ]; then \
		echo "❌ Error: Please specify a model file."; \
		echo "👉 Usage: make run <model_filename>"; \
		echo "💡 Example: make run my_model.gguf"; \
		exit 1; \
	fi
	@if [ ! -f "$(MODELS_DIR)/$(MODEL_FILE)" ]; then \
		echo "❌ Error: Model file $(MODELS_DIR)/$(MODEL_FILE) not found!"; \
		exit 1; \
	fi
	@echo "🚀 Starting $(CONTAINER_NAME) with model $(MODEL_FILE)..."
	@if [ "$(ENABLE_FILE_LOGGING)" = "true" ]; then \
		mkdir -p "$(LOG_DIR)"; \
		podman run -d \
			--name $(CONTAINER_NAME) \
			-p $(PORT):8080 \
			-v "$(MODELS_DIR):/models" \
			-v "$(LOG_DIR):/logs" \
			--device /dev/kfd \
			--device /dev/dri \
			--entrypoint /bin/sh \
			$(IMAGE) \
			-c "/app/llama-server -m \"/models/$(MODEL_FILE)\" $(EXTRA_ARGS) 2>&1 | tee /logs/llama-server.log"; \
		echo "✅ Server started! Logs are being written to $(LOG_DIR)/llama-server.log"; \
		echo "   You can also check them with: make logs"; \
	else \
		podman run -d \
			--name $(CONTAINER_NAME) \
			-p $(PORT):8080 \
			-v "$(MODELS_DIR):/models" \
			--device /dev/kfd \
			--device /dev/dri \
			$(IMAGE) \
			-m "/models/$(MODEL_FILE)" $(EXTRA_ARGS); \
		echo "✅ Server started! Check logs with: make logs"; \
	fi

download:
	@if [ -n "$(URL)" ]; then \
		echo "⬇️ Downloading from $(URL)..."; \
		wget -c "$(URL)" -P "$(MODELS_DIR)" || curl -LC - -o "$(MODELS_DIR)/$$(basename $(URL))" "$(URL)"; \
		echo "✅ Download complete!"; \
	elif [ -n "$(DOWNLOAD_ARGS)" ]; then \
		echo "⬇️ Downloading $(DOWNLOAD_ARGS) using hf cli..."; \
		hf download $(DOWNLOAD_ARGS) --local-dir "$(MODELS_DIR)"; \
		echo "✅ Download complete!"; \
	else \
		echo "❌ Error: Please specify what to download."; \
		echo "👉 Usage (HuggingFace): make download <repo_id> <filename>"; \
		echo "💡 Example: make download TheBloke/Llama-2-7B-Chat-GGUF llama-2-7b-chat.Q4_K_M.gguf"; \
		echo "👉 Usage (URL): make download URL=<direct_url>"; \
		exit 1; \
	fi

stop:
	@echo "🛑 Stopping $(CONTAINER_NAME)..."
	@podman stop $(CONTAINER_NAME) 2>/dev/null || true
	@podman rm $(CONTAINER_NAME) 2>/dev/null || true

logs:
	@podman logs -f $(CONTAINER_NAME)

help:
	@echo "🦙 Llama.cpp Server Makefile"
	@echo ""
	@echo "Usage:"
	@echo "  make run <model.gguf>   Start server with a local model"
	@echo "  make stop               Stop the server"
	@echo "  make logs               View server logs"
	@echo "  make help               Show this help message"
	@echo ""
	@echo "Downloading models:"
	@echo "  make download <repo> <file>   Download from HuggingFace (requires hf cli)"
	@echo "  make download URL=<url>       Download from a direct URL"
	@echo ""
	@echo "Environment Variables (can be overridden):"
	@echo "  PORT=8080                     Exposed port"
	@echo "  MODELS_DIR=$(CURDIR)          Directory for models"
	@echo "  ENABLE_FILE_LOGGING=false     Set to true to pipe logs to file"
	@echo "  LOG_DIR=$(CURDIR)/llama-logs  Directory for log files"
	@echo "  N_GPU_LAYERS=99               Number of layers to offload to GPU"
	@echo "  N_CTX=4096                    Context window size"
	@echo "  THREADS=6                     Number of CPU threads to use"
	@echo "  EXTRA_ARGS=\"...\"              Extra llama-server arguments"

# Catch-all target: route all unknown targets here to do nothing.
# This prevents Make from failing when passing arguments like filenames or URLs.
%:
	@:
