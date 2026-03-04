# Makefile — AncientVision developer ergonomics
# Run `make` or `make help` to see all available targets.

.DEFAULT_GOAL := help

.PHONY: help build firmware flutter ml collect train monitor dev-ml dev-flutter dev-firmware \
        test simulate backup logs clean report drift validate-config quality-check \
        label replay schedule playback sync annotate analyze apk quantize benchmark load-test \
        validate-data dry-run e2e status health augment online-learn tune onnx \
        live-dashboard ab-test augmentation-report \
        serve-model session-report calibration-check confidence-analysis monitor-model \
        freq-analysis compare-devices site-summary \
        export-gps export-parquet feature-importance feature-selection evaluate \
        aggregate-stats anomaly-timeline compare-sessions cross-device-eval ensemble-predict \
        ensemble-train gen-precursor hyperparameter-search merge-sessions model-comparison \
        plot-session reset pipeline run-pipeline send-alert simulate-anomaly \
        threshold-optimize train-autoencoder training-smoke visualize-features visualize-latent \
        field-report calibrate drift-check retrain-advisor \
        session-risk ppv-trend \
        noise-floor event-duration \
        training-history feature-importance-report

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
	@echo "  analyze        Run Flutter analyzer (check for lint issues)"
	@echo "  apk            Build Flutter release APK"
	@echo "  quantize       Run INT8 quantization on ML models"
	@echo "  benchmark      Run inference benchmark (100 runs)"
	@echo "  load-test      Run API load test (500 requests, p95 latency)"
	@echo "  validate-data  Validate field training data integrity"
	@echo "  dry-run        Dry run training pipeline to check all preconditions"
	@echo "  e2e            Run end-to-end pipeline integration tests"
	@echo ""
	@echo "  status         Show system-wide pipeline and model status"
	@echo "  health         Ping all services and show status table"
	@echo "  augment        Augment training data with Gaussian noise"
	@echo "  online-learn   Fine-tune models with recent field data"
	@echo "  tune           Auto-tune classification thresholds from calibration data"
	@echo "  onnx           Export TFLite models to ONNX format"
	@echo ""
	@echo "  live-dashboard        Live curses terminal dashboard (polls collector API)"
	@echo "  ab-test               A/B compare two .tflite models (set MODEL_A= MODEL_B=)"
	@echo "  augmentation-report   Class distribution + augmentation recommendations"
	@echo ""
	@echo "  serve-model           Start lightweight HTTP model inference server (port 8766)"
	@echo "  session-report        Generate Markdown report from a session CSV (set SESSION_CSV=)"
	@echo "  calibration-check     Verify device calibration quality from field CSVs"
	@echo "  confidence-analysis   Analyze model confidence distribution and calibration (ECE)"
	@echo "  monitor-model         Check deployed model accuracy against labeled field data"
	@echo ""
	@echo "  freq-analysis         Analyze seismic frequency bands in field data"
	@echo "  compare-devices       Compare vibration patterns across multiple devices"
	@echo "  site-summary          Generate comprehensive site safety summary report"
	@echo ""
	@echo "  export-gps            Export GPS track as GPX or KML (set FORMAT=kml for KML)"
	@echo "  export-parquet        Export field CSVs to Apache Parquet format"
	@echo "  feature-importance    Analyze ML model feature importance"
	@echo "  feature-selection     Run automated feature selection pipeline"
	@echo "  evaluate              Run model evaluation suite"
	@echo "  aggregate-stats       Aggregate statistics from multiple sessions"
	@echo "  anomaly-timeline      Generate anomaly event timeline"
	@echo "  compare-sessions      Compare two field sessions side-by-side"
	@echo "  cross-device-eval     Cross-device evaluation on labeled data"
	@echo "  ensemble-predict      Run ensemble model predictions"
	@echo "  ensemble-train        Train ensemble models"
	@echo "  gen-precursor         Generate precursor training data"
	@echo "  hyperparameter-search Run hyperparameter optimization"
	@echo "  merge-sessions        Merge multiple session CSVs into one"
	@echo "  model-comparison      Compare multiple models side-by-side"
	@echo "  plot-session          Plot vibration data from a session"
	@echo "  reset                 Reset pipeline state and caches"
	@echo "  run-pipeline          Run full training pipeline once"
	@echo "  send-alert            Send test alert (Slack/email)"
	@echo "  simulate-anomaly      Simulate anomaly event for testing"
	@echo "  threshold-optimize    Optimize classification thresholds"
	@echo "  train-autoencoder     Train autoencoder model"
	@echo "  training-smoke        Run smoke test on training pipeline"
	@echo "  visualize-features    Visualize extracted features"
	@echo "  visualize-latent      Visualize autoencoder latent space"
	@echo "  field-report          Generate field data report"
	@echo "  calibrate             Interactive device calibration"
	@echo "  drift-check           Check for data drift between collected data and training baseline"
	@echo "  retrain-advisor       Evaluate whether ML model retraining is recommended"
	@echo "  session-risk          Generate per-session risk assessment report"
	@echo "  ppv-trend             Analyze PPV trend acceleration in field data"
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
		scripts/test_new_scripts.py \
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

status:
	@echo "==> AncientVision system status report..."
	python scripts/pipeline_status.py --data-dir ./data/field --assets-dir app/assets/ml

augment:
	@echo "==> Augmenting training data with Gaussian noise..."
	@if [ -f scripts/augment_training_data.py ]; then \
		python scripts/augment_training_data.py --data-dir ./data/field; \
	else \
		echo "WARNING: scripts/augment_training_data.py not found"; \
	fi

health:
	@echo "==> Running service health check..."
	python scripts/health_check.py --timeout 5

online-learn:
	@echo "==> Running online fine-tuning on field data..."
	@if [ -f scripts/online_learning.py ]; then \
		python scripts/online_learning.py --data-dir ./data/field; \
	else \
		echo "WARNING: scripts/online_learning.py not found"; \
	fi

tune:
	@echo "==> Auto-tuning classification thresholds..."
	@if [ -f scripts/tune_thresholds.py ]; then \
		python scripts/tune_thresholds.py --data-dir ./data/field; \
	else \
		echo "WARNING: scripts/tune_thresholds.py not found"; \
	fi

onnx:
	@echo "==> Exporting models to ONNX format..."
	@if [ -f scripts/onnx_export.py ]; then \
		python scripts/onnx_export.py --assets-dir app/assets/ml; \
	else \
		echo "WARNING: scripts/onnx_export.py not found"; \
	fi

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

# ---------------------------------------------------------------------------
# Build & Analysis
# ---------------------------------------------------------------------------

analyze:
	@echo "==> Running Flutter analyze..."
	cd app && flutter analyze

apk:
	@echo "==> Building Flutter release APK..."
	cd app && flutter build apk --release
	@echo "APK: app/build/app/outputs/flutter-apk/app-release.apk"

quantize:
	@echo "==> Running INT8 quantization on ML models..."
	@if [ -f scripts/quantize_models.py ]; then \
		python scripts/quantize_models.py --assets-dir app/assets/ml; \
	else \
		echo "WARNING: scripts/quantize_models.py not found"; \
	fi

benchmark:
	@echo "==> Running inference benchmark..."
	@if [ -f scripts/inference_benchmark.py ]; then \
		python scripts/inference_benchmark.py --n-runs 100 --model both; \
	else \
		echo "WARNING: scripts/inference_benchmark.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Testing & Validation
# ---------------------------------------------------------------------------

load-test:
	@echo "==> Running load test against local collector..."
	python scripts/load_test.py --url http://localhost:8765 --n 200 --concurrency 10

validate-data:
	@echo "==> Validating training data..."
	@if [ -f scripts/validate_training_data.py ]; then \
		python scripts/validate_training_data.py --data-dir ./data/field; \
	else \
		echo "WARNING: scripts/validate_training_data.py not found"; \
	fi

dry-run: ## Dry run training pipeline to check all preconditions
	@echo "==> Dry run training pipeline (no actual training)..."
	@if [ -f scripts/training_pipeline_dry_run.py ]; then \
		python scripts/training_pipeline_dry_run.py; \
	else \
		echo "WARNING: scripts/training_pipeline_dry_run.py not found"; \
	fi

e2e:
	@echo "==> Running end-to-end pipeline tests..."
	python -m pytest scripts/test_e2e_pipeline.py -v

# ---------------------------------------------------------------------------
# Live dashboard / A-B test / augmentation report
# ---------------------------------------------------------------------------

live-dashboard:
	@echo "==> Starting live terminal dashboard (Ctrl+C or q to quit)..."
	python scripts/live_dashboard.py --url http://localhost:8765

ab-test:
	@if [ -z "$(MODEL_A)" ] || [ -z "$(MODEL_B)" ]; then \
		echo ""; \
		echo "Usage:  make ab-test MODEL_A=path/to/a.tflite MODEL_B=path/to/b.tflite"; \
		echo ""; \
		echo "Example:"; \
		echo "  make ab-test \\"; \
		echo "    MODEL_A=app/assets/ml/precursor_classifier.tflite \\"; \
		echo "    MODEL_B=app/assets/ml/precursor_classifier_v2.tflite"; \
		echo ""; \
		exit 1; \
	fi
	@echo "==> Running A/B model comparison..."
	python scripts/ab_test_models.py \
		--model-a "$(MODEL_A)" \
		--model-b "$(MODEL_B)" \
		$(if $(SCALER),--scaler "$(SCALER)",) \
		$(if $(N_SAMPLES),--n-samples "$(N_SAMPLES)",)

augmentation-report:
	@echo "==> Generating data augmentation report..."
	python scripts/data_augmentation_report.py --data-dir ./data/field

# ---------------------------------------------------------------------------
# Model inference server / session report / calibration check
# ---------------------------------------------------------------------------

serve-model:
	@echo "==> Starting model inference server on port 8766..."
	python scripts/model_serve.py --assets-dir app/assets/ml

session-report:
	@if [ -z "$(SESSION_CSV)" ]; then \
		echo ""; \
		echo "Usage:  make session-report SESSION_CSV=path/to/session.csv"; \
		echo ""; \
		echo "Options (optional):"; \
		echo "  OUTPUT=report.md        Output file (default: stdout)"; \
		echo "  FORMAT=md|html          Output format (default: md)"; \
		echo "  SITE_NAME='Paros Dig'   Site name label in report"; \
		echo ""; \
		exit 1; \
	fi
	@echo "==> Generating session report from: $(SESSION_CSV)"
	python scripts/session_report.py \
		--session-csv "$(SESSION_CSV)" \
		$(if $(OUTPUT),--output "$(OUTPUT)",) \
		$(if $(FORMAT),--format "$(FORMAT)",) \
		$(if $(SITE_NAME),--site-name "$(SITE_NAME)",)

calibration-check:
	@echo "==> Checking device calibration quality from ./data/field..."
	python scripts/device_calibration_check.py --data-dir ./data/field

confidence-analysis:
	@echo "==> Analyzing model confidence and calibration..."
	python scripts/model_confidence_analysis.py \
		--assets-dir app/assets/ml \
		$(if $(N_SAMPLES),--n-samples "$(N_SAMPLES)",) \
		$(if $(OUTPUT),--output "$(OUTPUT)",) \
		$(if $(SEED),--seed "$(SEED)",)

monitor-model:
	@echo "==> Checking model performance against field data..."
	python scripts/model_monitor.py \
		--assets-dir app/assets/ml \
		--data-dir ./data/field \
		--once \
		$(if $(SET_BASELINE),--set-baseline,) \
		$(if $(OUTPUT),--output "$(OUTPUT)",)

# ---------------------------------------------------------------------------
# Analysis & Comparison scripts
# ---------------------------------------------------------------------------

freq-analysis:
	@echo "==> Analyzing seismic frequency bands in field data..."
	python scripts/seismic_frequency_analysis.py --data-dir ./data/field \
		$(if $(OUTPUT),--output "$(OUTPUT)",)

compare-devices:
	@echo "==> Comparing vibration patterns across devices..."
	python scripts/compare_devices.py --data-dir ./data/field \
		$(if $(OUTPUT),--output "$(OUTPUT)",)

site-summary:
	@echo "==> Generating site safety summary report..."
	python scripts/site_summary_report.py \
		--data-dir ./data/field \
		$(if $(SITE_NAME),--site-name "$(SITE_NAME)",) \
		$(if $(OUTPUT),--output "$(OUTPUT)",)

# ---------------------------------------------------------------------------
# GPS & Export targets
# ---------------------------------------------------------------------------

export-gps:
	@echo "==> Exporting GPS track from field sessions..."
	python scripts/export_gps_track.py \
		--data-dir ./data/field \
		--format $(or $(FORMAT),gpx) \
		$(if $(OUTPUT),--output "$(OUTPUT)",)

export-parquet:
	@echo "==> Exporting field CSVs to Parquet format..."
	@if [ -f scripts/export_parquet.py ]; then \
		python scripts/export_parquet.py --data-dir ./data/field; \
	else \
		echo "WARNING: scripts/export_parquet.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Feature Analysis targets
# ---------------------------------------------------------------------------

feature-importance:
	@echo "==> Analyzing model feature importance..."
	@if [ -f scripts/feature_importance.py ]; then \
		python scripts/feature_importance.py \
			--assets-dir app/assets/ml \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/feature_importance.py not found"; \
	fi

feature-selection:
	@echo "==> Running automated feature selection..."
	@if [ -f scripts/feature_selection.py ]; then \
		python scripts/feature_selection.py --data-dir ./data/field; \
	else \
		echo "WARNING: scripts/feature_selection.py not found"; \
	fi

evaluate:
	@echo "==> Running model evaluation suite..."
	@if [ -f scripts/evaluate_models.py ]; then \
		python scripts/evaluate_models.py \
			--assets-dir app/assets/ml \
			--data-dir ./data/field; \
	else \
		echo "WARNING: scripts/evaluate_models.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Statistics & Aggregation targets
# ---------------------------------------------------------------------------

aggregate-stats:
	@echo "==> Aggregating statistics from sessions..."
	@if [ -f scripts/aggregate_stats.py ]; then \
		python scripts/aggregate_stats.py --data-dir ./data/field; \
	else \
		echo "WARNING: scripts/aggregate_stats.py not found"; \
	fi

anomaly-timeline:
	@echo "==> Generating anomaly event timeline..."
	@if [ -f scripts/anomaly_timeline.py ]; then \
		python scripts/anomaly_timeline.py --data-dir ./data/field \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/anomaly_timeline.py not found"; \
	fi

compare-sessions:
	@echo "==> Comparing two field sessions..."
	@if [ -z "$(SESSION1)" ] || [ -z "$(SESSION2)" ]; then \
		echo "Usage: make compare-sessions SESSION1=path/to/s1.csv SESSION2=path/to/s2.csv"; exit 1; \
	fi
	@if [ -f scripts/compare_sessions.py ]; then \
		python scripts/compare_sessions.py "$(SESSION1)" "$(SESSION2)" \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/compare_sessions.py not found"; \
	fi

cross-device-eval:
	@echo "==> Running cross-device evaluation..."
	@if [ -f scripts/cross_device_eval.py ]; then \
		python scripts/cross_device_eval.py --data-dir ./data/field \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/cross_device_eval.py not found"; \
	fi

merge-sessions:
	@echo "==> Merging multiple session CSVs..."
	@if [ -z "$(SESSIONS)" ]; then \
		echo "Usage: make merge-sessions SESSIONS='path1.csv path2.csv path3.csv'"; exit 1; \
	fi
	@if [ -f scripts/merge_sessions.py ]; then \
		python scripts/merge_sessions.py $(SESSIONS) \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/merge_sessions.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Model Training & Ensemble targets
# ---------------------------------------------------------------------------

ensemble-predict:
	@echo "==> Running ensemble model predictions..."
	@if [ -f scripts/ensemble_predict.py ]; then \
		python scripts/ensemble_predict.py \
			--assets-dir app/assets/ml \
			$(if $(DATA),--data "$(DATA)",) \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/ensemble_predict.py not found"; \
	fi

ensemble-train:
	@echo "==> Training ensemble models..."
	@if [ -f scripts/ensemble_train.py ]; then \
		python scripts/ensemble_train.py --data-dir ./data/field \
			$(if $(OUTPUT_DIR),--output-dir "$(OUTPUT_DIR)",); \
	else \
		echo "WARNING: scripts/ensemble_train.py not found"; \
	fi

gen-precursor:
	@echo "==> Generating precursor training data..."
	@if [ -f scripts/generate_precursor_data.py ]; then \
		python scripts/generate_precursor_data.py --output ./data/field/precursor_training.csv; \
	else \
		echo "WARNING: scripts/generate_precursor_data.py not found"; \
	fi

hyperparameter-search:
	@echo "==> Running hyperparameter optimization..."
	@if [ -f scripts/hyperparameter_search.py ]; then \
		python scripts/hyperparameter_search.py --data-dir ./data/field \
			$(if $(N_TRIALS),--n-trials "$(N_TRIALS)",) \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/hyperparameter_search.py not found"; \
	fi

model-comparison:
	@echo "==> Comparing multiple models..."
	@if [ -f scripts/model_comparison.py ]; then \
		python scripts/model_comparison.py --assets-dir app/assets/ml \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/model_comparison.py not found"; \
	fi

train-autoencoder:
	@echo "==> Training autoencoder model..."
	@if [ -f scripts/train_autoencoder.py ]; then \
		python scripts/train_autoencoder.py --data-dir ./data/field \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/train_autoencoder.py not found"; \
	fi

threshold-optimize:
	@echo "==> Optimizing classification thresholds..."
	@if [ -f scripts/threshold_optimizer.py ]; then \
		python scripts/threshold_optimizer.py --data-dir ./data/field \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/threshold_optimizer.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Visualization & Plotting targets
# ---------------------------------------------------------------------------

plot-session:
	@echo "==> Plotting vibration data from session..."
	@if [ -z "$(SESSION_CSV)" ]; then \
		echo "Usage: make plot-session SESSION_CSV=path/to/session.csv"; exit 1; \
	fi
	@if [ -f scripts/plot_session.py ]; then \
		python scripts/plot_session.py "$(SESSION_CSV)" \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/plot_session.py not found"; \
	fi

visualize-features:
	@echo "==> Visualizing extracted features..."
	@if [ -f scripts/visualize_features.py ]; then \
		python scripts/visualize_features.py --data-dir ./data/field \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/visualize_features.py not found"; \
	fi

visualize-latent:
	@echo "==> Visualizing autoencoder latent space..."
	@if [ -f scripts/visualize_latent_space.py ]; then \
		python scripts/visualize_latent_space.py \
			--assets-dir app/assets/ml \
			$(if $(DATA_DIR),--data-dir "$(DATA_DIR)",) \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/visualize_latent_space.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Pipeline Management targets
# ---------------------------------------------------------------------------

run-pipeline:
	@echo "==> Running full ML training pipeline..."
	@if [ -f scripts/run_pipeline.py ]; then \
		python scripts/run_pipeline.py; \
	else \
		echo "WARNING: scripts/run_pipeline.py not found"; \
	fi

reset:
	@echo "==> Resetting pipeline state..."
	@if [ -f scripts/reset_pipeline.py ]; then \
		python scripts/reset_pipeline.py; \
	else \
		echo "WARNING: scripts/reset_pipeline.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Utilities & Testing targets
# ---------------------------------------------------------------------------

send-alert:
	@echo "==> Sending test alert..."
	@if [ -f scripts/send_alert.py ]; then \
		python scripts/send_alert.py \
			$(if $(CHANNEL),--channel "$(CHANNEL)",) \
			$(if $(MESSAGE),--message "$(MESSAGE)",); \
	else \
		echo "WARNING: scripts/send_alert.py not found"; \
	fi

simulate-anomaly:
	@echo "==> Simulating anomaly event..."
	@if [ -f scripts/simulate_anomaly.py ]; then \
		python scripts/simulate_anomaly.py \
			$(if $(ANOMALY_TYPE),--type "$(ANOMALY_TYPE)",) \
			$(if $(DURATION),--duration "$(DURATION)",); \
	else \
		echo "WARNING: scripts/simulate_anomaly.py not found"; \
	fi

training-smoke:
	@echo "==> Running training pipeline smoke test..."
	@if [ -f scripts/training_smoke_test.py ]; then \
		python scripts/training_smoke_test.py; \
	else \
		echo "WARNING: scripts/training_smoke_test.py not found"; \
	fi

field-report:
	@echo "==> Generating field data report..."
	@if [ -f scripts/field_report.py ]; then \
		python scripts/field_report.py --data-dir ./data/field \
			$(if $(OUTPUT),--output "$(OUTPUT)",); \
	else \
		echo "WARNING: scripts/field_report.py not found"; \
	fi

calibrate:
	@echo "==> Starting interactive device calibration..."
	@if [ -f scripts/calibrate.py ]; then \
		python scripts/calibrate.py; \
	else \
		echo "WARNING: scripts/calibrate.py not found"; \
	fi

# ---------------------------------------------------------------------------
# Drift detection and retraining advisor
# ---------------------------------------------------------------------------

drift-check: ## Check for data drift between collected data and training baseline
	python scripts/data_drift_detector.py

retrain-advisor: ## Evaluate whether ML model retraining is recommended
	python scripts/retrain_advisor.py

session-risk: ## Generate per-session risk assessment report
	python scripts/session_risk_report.py

ppv-trend: ## Analyze PPV trend acceleration in field data
	python scripts/ppv_trend_analysis.py

noise-floor: ## Analyze sensor noise floor for each device
	python scripts/sensor_noise_floor.py

event-duration: ## Analyze alert event durations and shapes
	python scripts/event_duration_analysis.py

training-history: ## Show ML training run history and accuracy trends
	python scripts/training_history.py

feature-importance-report: ## Analyze feature importance using permutation method
	python scripts/feature_importance_report.py
