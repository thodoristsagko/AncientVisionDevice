# Makefile — AncientVision developer ergonomics
# Run `make` or `make help` to see all available targets.

.DEFAULT_GOAL := help

.PHONY: help build firmware flutter ml collect train monitor dev-ml dev-flutter dev-firmware \
        test simulate backup logs clean report drift validate-config quality-check \
        label replay schedule playback sync annotate

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
	@echo "  monitor        Start Prometheus + Grafana monitoring stack"
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
	@echo "  report         Generate Markdown field report from collected CSVs"
	@echo "  drift          Check feature drift vs training distribution"
	@echo "  validate-config Validate all ML JSON config/scaler files"
	@echo "  quality-check  Show data quality dashboard (one-shot)"
	@echo "  label          Interactive session labeling CLI"
	@echo "  annotate       Auto-label unlabeled CSV rows by threshold"
	@echo "  replay         Replay a field CSV against the collector"
	@echo "  schedule       Trigger retraining check (--once mode)"
	@echo "  sync           Sync field CSVs to Firebase Storage"
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

monitor:
	@echo "==> Starting monitoring stack (Prometheus + Grafana)..."
	docker compose -f docker-compose.monitoring.yml up -d
	@echo "Prometheus: http://localhost:9090"
	@echo "Grafana:    http://localhost:3000 (admin/ancientvision)"

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
	python -m pytest \
		docker/collect/test_app.py \
		docker/watcher/test_watch.py \
		scripts/test_run_pipeline.py \
		scripts/test_simulate.py \
		scripts/test_integration.py \
		scripts/test_field_report.py \
		scripts/test_reset_pipeline.py \
		scripts/test_evaluate_models.py \
		scripts/test_visualize.py \
		scripts/test_training_quality.py \
		-v

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

# ---------------------------------------------------------------------------
# Field data tools
# ---------------------------------------------------------------------------

report:
	@echo "==> Generating field data report..."
	python scripts/generate_report.py --data-dir ./data/field --output ./data/field_report.md
	@echo "Report written to: ./data/field_report.md"

drift:
	@echo "==> Checking feature drift vs training distribution..."
	python scripts/data_drift_check.py --data-dir ./data/field

validate-config:
	@echo "==> Validating ML config and scaler files..."
	python scripts/validate_config.py --assets-dir app/assets/ml

quality-check:
	@echo "==> Data quality dashboard (one-shot)..."
	python scripts/data_quality_dashboard.py --data-dir ./data/field --refresh 0

label:
	@echo "==> Starting interactive session labeler..."
	@if [ -z "$(CSV)" ]; then \
		echo "Usage: make label CSV=path/to/session.csv"; exit 1; \
	fi
	python scripts/label_session.py $(CSV)

annotate:
	@echo "==> Auto-labeling unlabeled CSV rows by threshold..."
	python scripts/batch_label.py --data-dir ./data/field

replay:
	@echo "==> Replaying session CSV against collector..."
	@if [ -z "$(CSV)" ]; then \
		echo "Usage: make replay CSV=path/to/session.csv [SPEED=1.0]"; exit 1; \
	fi
	python scripts/session_playback.py $(CSV) --speed $(or $(SPEED),1.0)

schedule:
	@echo "==> Running training scheduler check..."
	python scripts/training_scheduler.py --data-dir ./data/field --once

sync:
	@echo "==> Syncing field data to Firebase Storage..."
	@if [ -z "$(BUCKET)" ]; then \
		echo "Usage: make sync BUCKET=my-firebase-bucket"; exit 1; \
	fi
	python scripts/sync_to_firebase.py --data-dir ./data/field --bucket $(BUCKET)

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
