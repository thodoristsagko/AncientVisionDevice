# ML Architecture — AncientVision

## Overview

AncientVision uses two TFLite models running on the Android phone:

| Model | Purpose | Input | Output |
|-------|---------|-------|--------|
| **Autoencoder** | Anomaly detection — flags vibration patterns the model has never seen | 11 DSP features | Reconstruction error (float) |
| **Precursor Classifier** | 4-class soil hazard classification | 17 features (11 DSP + 6 trend) | Probability distribution over 4 classes |

Both models are small (< 50 KB TFLite) and run entirely on-device with no internet
connection required during inference.

---

## Architecture Overview

```
M5StickC Plus 2
  |-- IMU JSON (BLE)          --> BLE Parser (ble_parser.dart)
  |-- Raw Accel Binary (BLE)  --> RawAccelReassembler (ble_parser.dart)
          |
          v
  VibrationDspService (vibration_dsp_service.dart)
    FFT, DWT, kurtosis, spectral centroid, Arias intensity, CAV
          |
          +----> AdaptiveAnomalyService (adaptive_anomaly_service.dart)
          |        Autoencoder inference + rule-based fallback
          |        Outputs: AnomalyLevel (SAFE, ANOMALY, CRITICAL)
          |
          +----> PrecursorClassifierService (precursor_classifier_service.dart)
                   Precursor classifier inference
                   Outputs: class probabilities [normal, soil_creep,
                             crack_propagation, imminent_failure]
```

---

## Feature Sets

### Autoencoder Features (11)

The autoencoder is trained on normal ambient vibration only. An elevated
reconstruction error indicates the current pattern is anomalous.

| Index | Name | Unit | Description |
|-------|------|------|-------------|
| 0 | `rms` | g | RMS acceleration over the last window |
| 1 | `ppv` | mm/s | Peak Component Particle Velocity |
| 2 | `freq` | Hz | Dominant frequency |
| 3 | `crest` | — | Crest factor |
| 4 | `centroid` | Hz | Spectral centroid |
| 5 | `kurtosis` | — | Statistical kurtosis |
| 6 | `stalta` | — | Recursive STA/LTA ratio |
| 7 | `arias` | m/s | Arias intensity |
| 8 | `cav` | m/s | Cumulative Absolute Velocity |
| 9 | `temp` | °C | IMU die temperature (bias proxy) |
| 10 | `psdSlope` | dB/octave | Slope of the power spectral density (log-log fit) |

### Precursor Classifier Features (17)

The precursor classifier uses the same 11 DSP features plus 6 trend features that
capture how the signal is evolving over time.

| Index | Name | Description |
|-------|------|-------------|
| 0–10 | (same as autoencoder) | Current-window DSP features |
| 11 | `ppv_trend` | Ratio of current PPV to mean PPV over the last N windows |
| 12 | `freq_trend` | Ratio of current dominant frequency to recent mean |
| 13 | `kurtosis_trend` | Ratio of current kurtosis to recent mean |
| 14 | `stalta_trend` | Ratio of current STA/LTA to recent mean |
| 15 | `cusum_max` | Maximum CUSUM statistic over recent PPV history |
| 16 | `autoencoder_score` | Reconstruction error from the autoencoder (dimensionless) |

---

## Class Definitions

The precursor classifier recognises four classes, drawn from geotechnical literature:

| Class | Label | Description |
|-------|-------|-------------|
| 0 | `normal` | Ambient baseline — no hazard |
| 1 | `soil_creep` | Slow plastic deformation. PPV elevated, dominant frequency dropping. |
| 2 | `crack_propagation` | Impulsive bursts. High crest factor, kurtosis, and STA/LTA. |
| 3 | `imminent_failure` | Precursor to imminent slope failure. Strong signal across all metrics. |

A fifth pseudo-class `normal_human_activity` (footsteps, tools) is used during
synthetic training to help the model discriminate human-caused impulses from
geotechnical precursors; it is merged into `normal` for inference.

---

## Model Architecture

### Autoencoder

```
Input (11)
  --> Dense(8, relu)
  --> Dense(4, relu)     [bottleneck]
  --> Dense(8, relu)
  --> Dense(11, linear)  [reconstruction]
Loss: MSE
Optimizer: Adam
```

### Precursor Classifier

```
Input (17)
  --> Dense(16, relu)
  --> Dense(8, relu)
  --> Dense(4, softmax)
Loss: categorical_crossentropy
Optimizer: Adam
Class weights: balanced (computed from training distribution)
```

Both models are exported to TFLite with float32 weights (no quantisation) for
full-precision on-device inference.

---

## Training Data Pipeline

### 1. Synthetic Data Generation

Real labelled field data is scarce at this stage. Training data is generated
synthetically from feature distributions derived from geotechnical literature.

```python
# scripts/generate_precursor_data.py
generate_class("normal",              n=3000)
generate_class("normal_human_activity", n=1500)  # merged to normal
generate_class("soil_creep",          n=1000)
generate_class("crack_propagation",   n=800)
generate_class("imminent_failure",    n=500)
```

### 2. Augmentation

Each sample is augmented with Gaussian noise (sigma = 2% of feature range) to prevent
overfitting to exact boundary values.

### 3. Train / Validation / Test Split

| Split | Fraction | Purpose |
|-------|----------|---------|
| Train | 60% | Model fitting |
| Validation | 20% | Early stopping, hyperparameter selection |
| Test / Holdout | 20% | Final accuracy and AUC evaluation |

Stratified split preserves class proportions.

---

## Model Training Flow

```
1. Generate synthetic data (scripts/generate_precursor_data.py)
2. Fit StandardScaler on training data only — NEVER on val/test
3. 5-fold stratified cross-validation on train+val folds
   - Reports mean accuracy and AUC per fold
4. Train final model on full train set
   - EarlyStopping: patience=10, monitor=val_loss, restore_best_weights=True
   - Max epochs: 100
5. Evaluate on holdout test set
   - Classification report (precision, recall, F1 per class)
   - Confusion matrix
   - One-vs-rest ROC AUC
6. Compare against stored baseline accuracy
   - If new model >= baseline: export TFLite + scaler JSON
   - If new model < baseline: keep previous model (rollback)
7. Export artifacts
   - precursor_classifier.tflite
   - precursor_scaler.json  (means, stds for normalisation)
   - autoencoder.tflite
   - autoencoder_scaler.json
```

Early stopping prevents overfitting and reduces unnecessary training time on the
Docker-based trainer container.

---

## Deployment Flow

After training, model artifacts are copied to:

```
app/assets/ml/
  autoencoder.tflite
  autoencoder_scaler.json
  precursor_classifier.tflite
  precursor_scaler.json
```

These are bundled into the Flutter APK via `pubspec.yaml` assets. No network download
is required at runtime.

To deploy:

```bash
make flutter          # rebuilds the APK with updated assets
# then install APK on device:
adb install app/build/app/outputs/flutter-apk/app-release.apk
```

---

## Inference Pipeline on Phone

### Per BLE Window (~1.28 s)

```
RawAccelReassembler.onPacket(packet)
  |
  v [when 3 packets received]
VibrationDspService.process(float[] accelX, accelY, accelZ)
  --> FFT (Hanning window, Parseval-corrected)
  --> PSD (ENBW-normalised)
  --> Spectral centroid, PSD slope
  --> DWT (Haar, 4 levels)
  --> Kurtosis, Crest factor
  --> Arias intensity, CAV
  --> Returns: DspResult(rms, ppv, freq, crest, centroid, kurtosis,
                         stalta, arias, cav, temp, psdSlope)
  |
  +---> AdaptiveAnomalyService.update(DspResult)
  |       normalize features with autoencoder_scaler.json
  |       run autoencoder TFLite inference
  |       compute reconstruction error
  |       compare to calibrated noise threshold
  |       --> AnomalyLevel: SAFE | ANOMALY | CRITICAL
  |
  +---> PrecursorClassifierService.classify(DspResult, trendFeatures)
          normalize with precursor_scaler.json
          run classifier TFLite inference
          --> ClassProbabilities {normal, soil_creep, crack_propagation, imminent_failure}
```

### Rule-Based Fallback

When TFLite inference fails (model not loaded, version mismatch, exception during
inference), `AdaptiveAnomalyService` falls back to a weighted rule-based scorer:

| Rule | Source standard | Weight |
|------|----------------|--------|
| PPV > threshold | DIN 4150-3 | 3.0 |
| STA/LTA > 4.0 | Allen (1978) | 2.0 |
| CAV > threshold | EPRI TR-100082 | 2.5 |
| Crest > 6.0 | general | 1.5 |
| Kurtosis > 5.0 | general | 1.5 |
| RMS elevated | general | 1.0 |
| Seismic freq (1–10 Hz) | general | 1.0 |

The fallback never returns `AnomalyLevel.unknown` — a score of 0 maps to SAFE.

---

## Anomaly Levels and Thresholds

| Level | Meaning | Trigger |
|-------|---------|---------|
| `SAFE` | No anomaly detected | Reconstruction error below noise threshold |
| `ANOMALY` | Pattern not seen during calibration | Error > 2× noise threshold |
| `CRITICAL` | Imminent hazard indicators present | Error > 5× threshold OR `imminent_failure` class probability > 0.5 |

The noise threshold is computed during a 5-window calibration phase immediately after
startup or after a `CALIBRATE` BLE command. Until calibration completes, the system
reports `AnomalyLevel.unknown` and the safety view shows "Initializing".

---

## Retraining Trigger

The Docker-based pipeline automatically retrains when enough new field samples arrive:

```
data/field/.sample_count  (written by data-collector on every ingest)
    |
    v [polled every 60 s by docker/watcher/watch.py]
    if (current_count - baseline_count) >= TRIGGER_THRESHOLD (default: 100):
        write data/.retrain_trigger
    |
    v [ML trainer monitors data/.retrain_trigger]
        run full training pipeline
        evaluate against baseline
        if better: copy new TFLite to app/assets/ml/
        delete data/.retrain_trigger
        update baseline_count
```

The trigger threshold is configurable at runtime via `POST /config` with
`{"trigger_threshold": 200}`, or via the `TRIGGER_THRESHOLD` environment variable.
