# Makefile — AncientVision developer ergonomics
# Run `make` or `make help` to see all available targets.

.DEFAULT_GOAL := help

.PHONY: help build firmware flutter ml collect train dev-ml dev-flutter dev-firmware \
        test simulate backup logs clean

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

help:
	@echo ""
	@echo "AncientVision — available targets:"
	@echo ""
	@echo "  build          Build all three services (firmware, flutter, ml)"
	@echo "  firmware       Build firmware image only"
	@echo "  flutter        Build Flutter APK only"
	@echo "  ml             Run ML training only"
	@echo ""
	@echo "  collect        Start data-collector service (docker-compose.collect.yml)"
	@echo "  train          Start file-watcher + trainer (docker-compose.train.yml)"
	@echo ""
	@echo "  dev-ml         Interactive bash shell in ml container"
	@echo "  dev-flutter    Interactive bash shell in flutter container"
	@echo "  dev-firmware   Interactive bash shell in firmware container"
	@echo ""
	@echo "  test           Run all pytest suites (collect, watcher, scripts)"
	@echo "  simulate       Send 150 fake samples to collector (localhost:8765)"
	@echo "  backup         Run scripts/backup_data.sh"
	@echo "  logs           Tail logs from data-collector service"
	@echo "  clean          Stop all compose stacks and prune Docker system"
	@echo ""

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------

build:
	@echo "==> Building all services..."
	docker compose -f docker-compose.yml build

firmware:
	@echo "==> Building firmware service..."
	docker compose -f docker-compose.yml build firmware

flutter:
	@echo "==> Building Flutter APK..."
	docker compose -f docker-compose.yml build flutter
	docker compose -f docker-compose.yml run --rm flutter

ml:
	@echo "==> Running ML training..."
	docker compose -f docker-compose.yml build ml
	docker compose -f docker-compose.yml run --rm ml

# ---------------------------------------------------------------------------
# Runtime stacks
# ---------------------------------------------------------------------------

collect:
	@echo "==> Starting data-collector service..."
	docker compose -f docker-compose.collect.yml up

train:
	@echo "==> Starting file-watcher and trainer..."
	docker compose -f docker-compose.train.yml up

# ---------------------------------------------------------------------------
# Interactive dev shells
# ---------------------------------------------------------------------------

dev-ml:
	@echo "==> Opening bash shell in ml-dev container..."
	docker compose -f docker-compose.dev.yml run --rm ml-dev

dev-flutter:
	@echo "==> Opening bash shell in flutter-dev container..."
	docker compose -f docker-compose.dev.yml run --rm flutter-dev

dev-firmware:
	@echo "==> Opening bash shell in firmware-dev container..."
	docker compose -f docker-compose.dev.yml run --rm firmware-dev

# ---------------------------------------------------------------------------
# Testing
# ---------------------------------------------------------------------------

test:
	@echo "==> Running all pytest suites..."
	python -m pytest docker/collect/test_app.py docker/watcher/test_watch.py scripts/test_run_pipeline.py scripts/test_simulate.py -v

# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

simulate:
	@echo "==> Sending 150 fake samples to collector at localhost:8765..."
	@if [ -f scripts/simulate_field_data.py ]; then \
		python scripts/simulate_field_data.py --count 150; \
	else \
		echo "ERROR: scripts/simulate_field_data.py not found."; \
		echo "       Create it first, or run: make collect  (to start the collector)"; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

backup:
	@echo "==> Running backup script..."
	bash scripts/backup_data.sh

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

logs:
	@echo "==> Tailing logs from data-collector service..."
	docker compose -f docker-compose.collect.yml logs -f data-collector

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

clean:
	@echo "==> Stopping all compose stacks..."
	docker compose -f docker-compose.yml down --remove-orphans || true
	docker compose -f docker-compose.collect.yml down --remove-orphans || true
	docker compose -f docker-compose.train.yml down --remove-orphans || true
	docker compose -f docker-compose.dev.yml down --remove-orphans || true
	@echo "==> Pruning Docker system (containers, networks, dangling images)..."
	docker system prune -f
