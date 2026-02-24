# ML-Based Vibration Anomaly Detection — Design

## Goal
Replace the missing TFLite model with a working ML pipeline that:
1. Reduces the 99% false positive rate by learning site-specific normal baselines
2. Detects precursor patterns (soil_creep, crack_propagation, imminent_failure)

## Approach: Hybrid — Feature Autoencoder + Precursor Classifier

Two ML components running on-phone via TFLite, integrated into the existing 3-tier fallback chain.

## Component 1: Anomaly Autoencoder

- **Architecture**: Feedforward 11 → 8 → 4 → 8 → 11 (~500 params, <5KB TFLite)
- **Input**: 11 DSP features (rms, ppv, freq, crest, centroid, kurtosis, stalta, arias, cav, temp, psdSlope)
- **Output**: Reconstruction error → anomaly score (0–1)
- **Training**: Pre-trained base model shipped with app. On-site calibration (10–30 min) computes site-specific feature scaler (mean/std) and anomaly threshold (mean + 3σ of calibration reconstruction errors)
- **No on-device weight training** — TFLite limitation. Calibration adapts normalization + threshold only.

## Component 2: Precursor Classifier

- **Architecture**: Decision tree exported as TFLite (~2–3KB)
- **Input**: 11 DSP features + 6 trend features (PPV trend, freq trend, kurtosis trend, STA/LTA trend, CUSUM max, autoencoder anomaly score) = 17 total
- **Output**: Class (normal, soil_creep, crack_propagation, imminent_failure) + confidence
- **Training**: Synthetic data from published geotechnical literature:
  - Soil creep: linear PPV ramp, freq decay, kurtosis rise
  - Crack propagation: Poisson impulse events with decreasing inter-arrival times
  - Imminent failure: exponential PPV growth (Fukuzono/Voight curves), freq < 5 Hz
  - Normal: random sampling within baseline ± 2σ
- **Pre-shipped**, no on-site training needed

## Integration & Data Flow

```
DSP features (11) ──→ Autoencoder ──→ anomaly_score
                  └──→ + trend deltas (6) ──→ Precursor Classifier ──→ pattern + confidence
                                                        ↓
                              Merge: max(autoencoder_score, classifier_score)
                                        ↓
                              Adaptive Statistical (existing, unchanged)
                                        ↓
                              Rule-based fallback (existing, unchanged)
```

**Merging logic** (in `vibration_anomaly_service.dart`):
- Tier 1: Both autoencoder + classifier. ML score = max(autoencoder_score, classifier_confidence). Precursor pattern attached regardless of score.
- Tier 2: Adaptive statistical (unchanged)
- Tier 3: Rule-based (unchanged, always active as safety floor)
- Final score = max(ml_score, adaptive_score, rule_score) — highest severity wins

## Calibration UI

- "Calibrate Site" button in safety_view popup menu
- Progress display: sample count, estimated time remaining
- Minimum 5 min (600 samples). High-variance warning if CV > 0.5 on PPV.
- Site profiles saved to app documents, multiple profiles supported, selectable on connect

## New Files

- `lib/services/ml_anomaly_service.dart` — autoencoder inference, calibration collection, scaler/threshold management
- `lib/services/precursor_classifier_service.dart` — decision tree inference
- `lib/models/site_profile.dart` — site name, scaler params, threshold, creation date, model version
- `assets/models/base_autoencoder.tflite` — pre-trained base model
- `assets/models/precursor_classifier.tflite` — pre-trained decision tree
- `scripts/train_autoencoder.py` — base autoencoder training script
- `scripts/generate_precursor_data.py` — synthetic data generation + classifier training

## Error Handling & Safety

- ML is additive only — can raise severity, never suppress rule-based/adaptive alerts
- TFLite load failure → system operates as today (adaptive + rules)
- NaN/Inf from autoencoder → discard, fall through to adaptive
- Uncalibrated sites → autoencoder disabled, classifier still runs, adaptive + rules active
- Site profiles store model version; updated base model flags old profiles for recalibration
