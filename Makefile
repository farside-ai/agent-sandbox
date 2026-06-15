.DEFAULT_GOAL := help

# Container runtime: `docker` (default) or `podman`. Override per invocation:
#   make RUNTIME=podman up
RUNTIME ?= docker

# When using Podman, layer in the rootless overlay (keep-id) automatically.
COMPOSE_FILES := -f compose.yaml
ifeq ($(RUNTIME),podman)
COMPOSE_FILES += -f compose.podman.yaml
endif

COMPOSE := $(RUNTIME) compose $(COMPOSE_FILES)
COMPOSE_HARDENED := $(RUNTIME) compose $(COMPOSE_FILES) -f compose.hardened.yaml
IMAGE := agent-sandbox:latest

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

# Build via `<runtime> build` (not compose) so it doesn't require WORKSPACE_DIR.
build: ## Build the sandbox image
	$(RUNTIME) build -t $(IMAGE) .

up: ## Start the sandbox in the background
	$(COMPOSE) up -d

down: ## Stop and remove the sandbox container
	$(COMPOSE) down

restart: ## Restart the sandbox
	$(COMPOSE) restart

ps: ## Show sandbox status
	$(COMPOSE) ps

logs: ## Tail sandbox logs
	$(COMPOSE) logs -f

shell: ## Open a bash shell inside the sandbox
	$(COMPOSE) exec sandbox bash

claude: ## Run the Claude Code CLI inside the sandbox (use /login to authenticate)
	$(COMPOSE) exec sandbox claude

codex: ## Run the Codex CLI inside the sandbox (use to log in)
	$(COMPOSE) exec sandbox codex

doctor: ## Verify the agents and tools are installed and runnable
	@$(COMPOSE) exec sandbox sh -lc '\
		ok() { command -v "$$1" >/dev/null 2>&1 && echo "$$(command -v $$1)" || echo MISSING; }; \
		echo "claude-agent-acp: $$(ok claude-agent-acp)   (ACP adapter — Zed talks to this)"; \
		echo "codex-acp:        $$(ok codex-acp)   (ACP adapter — Zed talks to this)"; \
		echo "claude:           $$(claude --version 2>/dev/null || echo MISSING)"; \
		echo "codex:            $$(codex --version 2>/dev/null || echo MISSING)"; \
		echo "git:              $$(git --version)"; \
		echo "ripgrep:          $$(rg --version | head -1)"; \
		echo "workspace:        $$(pwd)"'

rebuild: ## Rebuild from scratch (e.g. to pull newer agent versions)
	$(RUNTIME) build --no-cache -t $(IMAGE) .

# --- Hardened mode (egress network wall; see compose.hardened.yaml) ---------

harden: ## Start the sandbox WITH the egress wall (allowlisted hosts only)
	$(COMPOSE_HARDENED) up -d --build

harden-down: ## Stop the hardened sandbox and its proxy
	$(COMPOSE_HARDENED) down

harden-rebuild: ## Rebuild the egress proxy (e.g. after editing the allowlist)
	$(COMPOSE_HARDENED) build egress-proxy
	$(COMPOSE_HARDENED) up -d

net-test: ## Prove the wall: an allowlisted host connects, a blocked one doesn't
	@$(COMPOSE_HARDENED) exec sandbox sh -lc '\
		echo "allowlisted (api.anthropic.com): $$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://api.anthropic.com/ || echo BLOCKED)"; \
		echo "blocked    (example.com):       $$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://example.com/ || echo BLOCKED)"'

.PHONY: help build up down restart ps logs shell claude codex doctor rebuild \
	harden harden-down harden-rebuild net-test
