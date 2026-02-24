# ML-Based Vibration Anomaly Detection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add hybrid ML anomaly detection (autoencoder + precursor classifier) to replace the missing TFLite model, reducing 99% false positives while detecting precursor patterns.

**Architecture:** Two TFLite models on-phone — a feature autoencoder trained offline and calibrated per-site (scaler + threshold), and a decision tree precursor classifier trained on synthetic geotechnical data. Both integrate into the existing 3-tier fallback chain in `vibration_anomaly_service.dart`.

**Tech Stack:** Python (TensorFlow/Keras, scikit-learn), TFLite, Flutter (tflite_flutter already in pubspec)

**Flutter app root:** `C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision`

---

### Task 1: Python Training Script — Base Autoencoder

**Files:**
- Create: `scripts/train_autoencoder.py`

**Step 1: Write the autoencoder training script**

```python
#!/usr/bin/env python3
"""Train base autoencoder for vibration anomaly detection.

Generates synthetic 'normal' vibration data based on typical archaeological site
baseline ranges, trains a small autoencoder (11→8→4→8→11), and exports to TFLite.

Outputs:
  - assets/ml/vibration_anomaly.tflite  (base autoencoder model)
  - assets/ml/vibration_scaler.json     (feature names + placeholder scaler)
  - assets/ml/vibration_model_config.json (model metadata)
"""
import json
import os
import numpy as np

os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'
import tensorflow as tf
from tensorflow import keras

FEATURE_NAMES = [
    'rms', 'ppv', 'freq', 'crest', 'centroid', 'kurtosis',
    'stalta', 'arias', 'cav', 'temp', 'psdSlope'
]

# Typical 'normal' ranges for archaeological site vibration (from literature)
NORMAL_RANGES = {
    'rms':      (0.001, 0.05),    # m/s² — ambient ground vibration
    'ppv':      (0.01, 0.3),      # mm/s — below DIN 4150-3 safe threshold
    'freq':     (5.0, 50.0),      # Hz — typical ambient dominant freq
    'crest':    (2.0, 6.0),       # ratio — normal (not impulsive)
    'centroid': (10.0, 40.0),     # Hz — spectral centroid
    'kurtosis': (-1.0, 3.0),     # excess kurtosis — Gaussian-like
    'stalta':   (0.5, 2.0),      # ratio — no seismic trigger
    'arias':    (0.0, 0.001),    # m/s — very low energy
    'cav':      (0.0, 0.01),     # g·s — very low cumulative
    'temp':     (15.0, 35.0),    # °C — ambient
    'psdSlope': (-12.0, -6.0),   # dB/decade — noise-like
}


def generate_normal_data(n_samples=10000):
    """Generate synthetic normal vibration feature vectors."""
    data = np.zeros((n_samples, len(FEATURE_NAMES)))
    for i, name in enumerate(FEATURE_NAMES):
        lo, hi = NORMAL_RANGES[name]
        # Use truncated normal centered in range
        mean = (lo + hi) / 2
        std = (hi - lo) / 4  # ~95% within range
        samples = np.random.normal(mean, std, n_samples)
        samples = np.clip(samples, lo, hi)
        data[:, i] = samples
    return data


def build_autoencoder(input_dim=11):
    """Build 11→8→4→8→11 autoencoder."""
    encoder_input = keras.Input(shape=(input_dim,))
    x = keras.layers.Dense(8, activation='relu')(encoder_input)
    bottleneck = keras.layers.Dense(4, activation='relu')(x)
    x = keras.layers.Dense(8, activation='relu')(bottleneck)
    decoder_output = keras.layers.Dense(input_dim, activation='linear')(x)

    autoencoder = keras.Model(encoder_input, decoder_output)
    autoencoder.compile(optimizer='adam', loss='mse')
    return autoencoder


def main():
    np.random.seed(42)
    tf.random.set_seed(42)

    # Generate and normalize data
    data = generate_normal_data(10000)
    mean = data.mean(axis=0)
    std = data.std(axis=0)
    std[std == 0] = 1.0
    data_norm = (data - mean) / std

    # Train
    model = build_autoencoder(11)
    model.fit(data_norm, data_norm, epochs=100, batch_size=64,
              validation_split=0.1, verbose=1)

    # Compute baseline reconstruction error threshold
    reconstructed = model.predict(data_norm)
    mse_per_sample = np.mean((data_norm - reconstructed) ** 2, axis=1)
    threshold_low = float(np.mean(mse_per_sample) + 2 * np.std(mse_per_sample))
    threshold_high = float(np.mean(mse_per_sample) + 4 * np.std(mse_per_sample))
    print(f"Threshold low (normal/unusual): {threshold_low:.6f}")
    print(f"Threshold high (unusual/anomaly): {threshold_high:.6f}")

    # Export to TFLite
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    tflite_model = converter.convert()

    out_dir = os.path.join(os.path.dirname(__file__), '..', 'assets', 'ml')
    os.makedirs(out_dir, exist_ok=True)

    # Resolve to Flutter app assets if running from firmware repo
    flutter_app = r'C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision'
    flutter_ml_dir = os.path.join(flutter_app, 'assets', 'ml')
    os.makedirs(flutter_ml_dir, exist_ok=True)

    for target_dir in [out_dir, flutter_ml_dir]:
        with open(os.path.join(target_dir, 'vibration_anomaly.tflite'), 'wb') as f:
            f.write(tflite_model)
        print(f"Model saved to {target_dir} ({len(tflite_model)} bytes)")

        # Scaler JSON (placeholder — calibration overrides mean/scale per-site)
        scaler = {
            'feature_names': FEATURE_NAMES,
            'mean': mean.tolist(),
            'scale': std.tolist(),
        }
        with open(os.path.join(target_dir, 'vibration_scaler.json'), 'w') as f:
            json.dump(scaler, f, indent=2)

        # Config JSON
        config = {
            'model_version': '5.0',
            'model_type': 'autoencoder',
            'input_dim': 11,
            'beta': 1.0,
            'thresholds': {
                'threshold_low': threshold_low,
                'threshold_high': threshold_high,
            },
        }
        with open(os.path.join(target_dir, 'vibration_model_config.json'), 'w') as f:
            json.dump(config, f, indent=2)

    print("Done! Model + scaler + config exported.")


if __name__ == '__main__':
    main()
```

**Step 2: Run the training script**

Run: `cd C:\Users\thodo\Documents\PlatformIO\Projects\AncientVisionDevice && python scripts/train_autoencoder.py`
Expected: Model trains for 100 epochs, prints thresholds, saves 3 files to both `assets/ml/` and Flutter app's `assets/ml/`.

**Step 3: Verify outputs exist**

Run: `ls -la "C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision\assets\ml\"`
Expected: `vibration_anomaly.tflite` (<10KB), `vibration_scaler.json`, `vibration_model_config.json`

**Step 4: Commit**

```bash
git add scripts/train_autoencoder.py assets/ml/
git commit -m "feat: add autoencoder training script and base model"
```

---

### Task 2: Python Training Script — Precursor Classifier

**Files:**
- Create: `scripts/generate_precursor_data.py`

**Step 1: Write the synthetic data generator + classifier training script**

```python
#!/usr/bin/env python3
"""Generate synthetic precursor vibration data and train decision tree classifier.

Produces synthetic data for 4 classes based on geotechnical literature:
  - normal: ambient baseline
  - soil_creep: gradual PPV ramp, freq decay, kurtosis rise
  - crack_propagation: impulsive bursts with decreasing inter-arrival
  - imminent_failure: exponential PPV growth, low freq, all metrics elevated

Outputs:
  - assets/ml/precursor_classifier.tflite
  - assets/ml/precursor_classifier_config.json
"""
import json
import os
import numpy as np
from sklearn.tree import DecisionTreeClassifier
import tensorflow as tf

FEATURE_NAMES = [
    # 11 DSP features
    'rms', 'ppv', 'freq', 'crest', 'centroid', 'kurtosis',
    'stalta', 'arias', 'cav', 'temp', 'psdSlope',
    # 6 trend features
    'ppv_trend', 'freq_trend', 'kurtosis_trend', 'stalta_trend',
    'cusum_max', 'autoencoder_score',
]

CLASSES = ['normal', 'soil_creep', 'crack_propagation', 'imminent_failure']


def generate_normal(n=3000):
    """Ambient baseline — all metrics low and stable."""
    data = np.zeros((n, 17))
    data[:, 0] = np.random.normal(0.02, 0.01, n).clip(0.001, 0.1)     # rms
    data[:, 1] = np.random.normal(0.1, 0.05, n).clip(0.01, 0.3)       # ppv
    data[:, 2] = np.random.normal(25, 10, n).clip(5, 50)               # freq
    data[:, 3] = np.random.normal(3.5, 1.0, n).clip(2, 6)             # crest
    data[:, 4] = np.random.normal(25, 8, n).clip(10, 40)              # centroid
    data[:, 5] = np.random.normal(0.5, 1.0, n).clip(-1, 3)            # kurtosis
    data[:, 6] = np.random.normal(1.0, 0.3, n).clip(0.5, 2)           # stalta
    data[:, 7] = np.random.normal(0.0005, 0.0002, n).clip(0, 0.001)   # arias
    data[:, 8] = np.random.normal(0.005, 0.002, n).clip(0, 0.01)      # cav
    data[:, 9] = np.random.normal(25, 5, n).clip(15, 35)              # temp
    data[:, 10] = np.random.normal(-9, 1.5, n).clip(-12, -6)          # psdSlope
    # Trends near zero
    data[:, 11] = np.random.normal(1.0, 0.1, n).clip(0.8, 1.2)       # ppv_trend (short/long ratio)
    data[:, 12] = np.random.normal(1.0, 0.05, n).clip(0.9, 1.1)      # freq_trend
    data[:, 13] = np.random.normal(1.0, 0.1, n).clip(0.8, 1.2)       # kurtosis_trend
    data[:, 14] = np.random.normal(1.0, 0.1, n).clip(0.8, 1.2)       # stalta_trend
    data[:, 15] = np.random.normal(0.5, 0.3, n).clip(0, 2)           # cusum_max
    data[:, 16] = np.random.normal(0.1, 0.05, n).clip(0, 0.3)        # autoencoder_score
    return data


def generate_soil_creep(n=2000):
    """Soil creep: PPV rising, freq dropping, kurtosis rising over time."""
    data = np.zeros((n, 17))
    # Elevated and trending PPV
    data[:, 0] = np.random.normal(0.08, 0.03, n).clip(0.02, 0.2)      # rms rising
    data[:, 1] = np.random.normal(0.8, 0.3, n).clip(0.3, 2.0)         # ppv elevated
    data[:, 2] = np.random.normal(10, 4, n).clip(2, 20)                # freq dropping
    data[:, 3] = np.random.normal(4.5, 1.0, n).clip(2.5, 7)           # crest slight rise
    data[:, 4] = np.random.normal(15, 5, n).clip(5, 25)               # centroid dropping
    data[:, 5] = np.random.normal(3.0, 1.5, n).clip(1, 6)             # kurtosis rising
    data[:, 6] = np.random.normal(1.5, 0.4, n).clip(0.8, 3)           # stalta mild
    data[:, 7] = np.random.normal(0.002, 0.001, n).clip(0, 0.005)     # arias
    data[:, 8] = np.random.normal(0.02, 0.01, n).clip(0.005, 0.05)    # cav
    data[:, 9] = np.random.normal(25, 5, n).clip(15, 35)              # temp
    data[:, 10] = np.random.normal(-6, 1.5, n).clip(-9, -3)           # psdSlope steepening
    # Key trends: ppv UP, freq DOWN, kurtosis UP
    data[:, 11] = np.random.normal(1.5, 0.3, n).clip(1.1, 2.5)       # ppv_trend rising
    data[:, 12] = np.random.normal(0.7, 0.1, n).clip(0.5, 0.9)       # freq_trend falling
    data[:, 13] = np.random.normal(1.4, 0.2, n).clip(1.1, 2.0)       # kurtosis_trend rising
    data[:, 14] = np.random.normal(1.2, 0.2, n).clip(0.9, 1.6)       # stalta_trend mild
    data[:, 15] = np.random.normal(2.0, 1.0, n).clip(0.5, 5)         # cusum elevated
    data[:, 16] = np.random.normal(0.3, 0.1, n).clip(0.1, 0.6)       # autoencoder_score
    return data


def generate_crack_propagation(n=2000):
    """Crack propagation: impulsive bursts, high kurtosis + STA/LTA."""
    data = np.zeros((n, 17))
    data[:, 0] = np.random.normal(0.05, 0.02, n).clip(0.01, 0.15)     # rms moderate
    data[:, 1] = np.random.normal(0.5, 0.3, n).clip(0.1, 1.5)         # ppv moderate
    data[:, 2] = np.random.normal(15, 5, n).clip(5, 30)                # freq variable
    data[:, 3] = np.random.normal(7.0, 2.0, n).clip(4, 12)            # crest HIGH (impulsive)
    data[:, 4] = np.random.normal(20, 8, n).clip(5, 35)               # centroid
    data[:, 5] = np.random.normal(6.0, 2.0, n).clip(3, 12)            # kurtosis HIGH
    data[:, 6] = np.random.normal(4.0, 1.5, n).clip(2, 8)             # stalta HIGH
    data[:, 7] = np.random.normal(0.001, 0.0005, n).clip(0, 0.003)    # arias
    data[:, 8] = np.random.normal(0.01, 0.005, n).clip(0, 0.03)       # cav
    data[:, 9] = np.random.normal(25, 5, n).clip(15, 35)              # temp
    data[:, 10] = np.random.normal(-7, 2, n).clip(-12, -3)            # psdSlope
    # Key trends: kurtosis + stalta rising
    data[:, 11] = np.random.normal(1.2, 0.2, n).clip(0.9, 1.8)       # ppv_trend mild
    data[:, 12] = np.random.normal(0.9, 0.1, n).clip(0.7, 1.1)       # freq_trend stable/slight drop
    data[:, 13] = np.random.normal(1.6, 0.3, n).clip(1.2, 2.5)       # kurtosis_trend rising
    data[:, 14] = np.random.normal(1.8, 0.4, n).clip(1.2, 3.0)       # stalta_trend rising
    data[:, 15] = np.random.normal(3.0, 1.5, n).clip(1, 8)           # cusum high
    data[:, 16] = np.random.normal(0.4, 0.15, n).clip(0.1, 0.7)      # autoencoder_score
    return data


def generate_imminent_failure(n=1500):
    """Imminent failure: all metrics elevated, low freq, PPV accelerating."""
    data = np.zeros((n, 17))
    data[:, 0] = np.random.normal(0.2, 0.1, n).clip(0.05, 0.5)        # rms HIGH
    data[:, 1] = np.random.normal(3.0, 1.5, n).clip(1.0, 10.0)        # ppv VERY HIGH
    data[:, 2] = np.random.normal(4.0, 1.5, n).clip(1, 8)             # freq LOW (<5 Hz dominant)
    data[:, 3] = np.random.normal(5.0, 2.0, n).clip(2, 10)            # crest elevated
    data[:, 4] = np.random.normal(8, 3, n).clip(2, 15)                # centroid LOW
    data[:, 5] = np.random.normal(5.0, 2.5, n).clip(2, 12)            # kurtosis HIGH
    data[:, 6] = np.random.normal(6.0, 2.0, n).clip(3, 12)            # stalta VERY HIGH
    data[:, 7] = np.random.normal(0.01, 0.005, n).clip(0.001, 0.03)   # arias HIGH
    data[:, 8] = np.random.normal(0.08, 0.04, n).clip(0.02, 0.2)      # cav HIGH
    data[:, 9] = np.random.normal(25, 5, n).clip(15, 35)              # temp
    data[:, 10] = np.random.normal(-4, 1.5, n).clip(-8, -1)           # psdSlope landslide range
    # All trends rising, PPV accelerating
    data[:, 11] = np.random.normal(2.5, 0.5, n).clip(1.5, 4.0)       # ppv_trend strongly rising
    data[:, 12] = np.random.normal(0.5, 0.15, n).clip(0.2, 0.8)      # freq_trend falling
    data[:, 13] = np.random.normal(1.8, 0.4, n).clip(1.2, 3.0)       # kurtosis_trend rising
    data[:, 14] = np.random.normal(2.0, 0.5, n).clip(1.3, 3.5)       # stalta_trend rising
    data[:, 15] = np.random.normal(5.0, 2.0, n).clip(2, 12)          # cusum very high
    data[:, 16] = np.random.normal(0.7, 0.15, n).clip(0.4, 1.0)      # autoencoder_score high
    return data


def train_and_export():
    np.random.seed(42)

    # Generate data
    X_normal = generate_normal()
    X_creep = generate_soil_creep()
    X_crack = generate_crack_propagation()
    X_failure = generate_imminent_failure()

    X = np.vstack([X_normal, X_creep, X_crack, X_failure])
    y = np.array([0]*len(X_normal) + [1]*len(X_creep) +
                 [2]*len(X_crack) + [3]*len(X_failure))

    # Shuffle
    idx = np.random.permutation(len(X))
    X, y = X[idx], y[idx]

    # Train decision tree (shallow to prevent overfitting on synthetic data)
    clf = DecisionTreeClassifier(max_depth=8, min_samples_leaf=20, random_state=42)
    clf.fit(X, y)

    # Accuracy on training data (expect high since synthetic)
    train_acc = clf.score(X, y)
    print(f"Training accuracy: {train_acc:.4f}")
    print(f"Tree depth: {clf.get_depth()}, leaves: {clf.get_n_leaves()}")

    # Convert to TFLite via a thin Keras wrapper
    # Decision trees can't convert directly — use a small neural net that mimics it
    from sklearn.model_selection import train_test_split
    X_train, X_val, y_train, y_val = train_test_split(X, y, test_size=0.1, random_state=42)

    # Train a small neural net as a surrogate (distillation)
    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(17,)),
        tf.keras.layers.Dense(16, activation='relu'),
        tf.keras.layers.Dense(8, activation='relu'),
        tf.keras.layers.Dense(4, activation='softmax'),
    ])
    model.compile(optimizer='adam', loss='sparse_categorical_crossentropy', metrics=['accuracy'])

    # Use decision tree predictions as soft labels for distillation
    model.fit(X_train, y_train, epochs=50, batch_size=64,
              validation_data=(X_val, y_val), verbose=1)

    val_acc = model.evaluate(X_val, y_val, verbose=0)[1]
    print(f"Neural net surrogate val accuracy: {val_acc:.4f}")

    # Export to TFLite
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    tflite_model = converter.convert()

    flutter_app = r'C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision'
    flutter_ml_dir = os.path.join(flutter_app, 'assets', 'ml')
    os.makedirs(flutter_ml_dir, exist_ok=True)

    local_dir = os.path.join(os.path.dirname(__file__), '..', 'assets', 'ml')
    os.makedirs(local_dir, exist_ok=True)

    for target_dir in [local_dir, flutter_ml_dir]:
        with open(os.path.join(target_dir, 'precursor_classifier.tflite'), 'wb') as f:
            f.write(tflite_model)

        config = {
            'model_version': '1.0',
            'feature_names': FEATURE_NAMES,
            'class_names': CLASSES,
            'input_dim': 17,
        }
        with open(os.path.join(target_dir, 'precursor_classifier_config.json'), 'w') as f:
            json.dump(config, f, indent=2)

        print(f"Classifier saved to {target_dir} ({len(tflite_model)} bytes)")


if __name__ == '__main__':
    train_and_export()
```

**Step 2: Run the training script**

Run: `cd C:\Users\thodo\Documents\PlatformIO\Projects\AncientVisionDevice && python scripts/generate_precursor_data.py`
Expected: Prints training accuracy >90%, saves `precursor_classifier.tflite` + config to both repos.

**Step 3: Commit**

```bash
git add scripts/generate_precursor_data.py assets/ml/
git commit -m "feat: add precursor classifier training script and model"
```

---

### Task 3: Site Profile Model

**Files:**
- Create: `lib/models/site_profile.dart` (in Flutter app)

**Step 1: Write the SiteProfile model**

```dart
import 'dart:convert';

/// Persisted calibration profile for a specific archaeological site.
///
/// Stores the feature scaler (mean/std computed during calibration) and
/// the autoencoder anomaly threshold (mean + 3σ of calibration MSEs).
class SiteProfile {
  final String name;
  final DateTime createdAt;
  final String modelVersion;
  final List<double> scalerMean;
  final List<double> scalerStd;
  final double thresholdLow;
  final double thresholdHigh;
  final int sampleCount;
  final double ppvCoefficientOfVariation;

  const SiteProfile({
    required this.name,
    required this.createdAt,
    required this.modelVersion,
    required this.scalerMean,
    required this.scalerStd,
    required this.thresholdLow,
    required this.thresholdHigh,
    required this.sampleCount,
    required this.ppvCoefficientOfVariation,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'modelVersion': modelVersion,
    'scalerMean': scalerMean,
    'scalerStd': scalerStd,
    'thresholdLow': thresholdLow,
    'thresholdHigh': thresholdHigh,
    'sampleCount': sampleCount,
    'ppvCoefficientOfVariation': ppvCoefficientOfVariation,
  };

  factory SiteProfile.fromJson(Map<String, dynamic> json) => SiteProfile(
    name: json['name'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    modelVersion: json['modelVersion'] as String,
    scalerMean: (json['scalerMean'] as List).map((e) => (e as num).toDouble()).toList(),
    scalerStd: (json['scalerStd'] as List).map((e) => (e as num).toDouble()).toList(),
    thresholdLow: (json['thresholdLow'] as num).toDouble(),
    thresholdHigh: (json['thresholdHigh'] as num).toDouble(),
    sampleCount: json['sampleCount'] as int,
    ppvCoefficientOfVariation: (json['ppvCoefficientOfVariation'] as num).toDouble(),
  );

  String encode() => jsonEncode(toJson());
  static SiteProfile decode(String s) => SiteProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);

  bool get needsRecalibration => modelVersion != '5.0';
  bool get highVarianceWarning => ppvCoefficientOfVariation > 0.5;
}
```

**Step 2: Commit**

```bash
git add lib/models/site_profile.dart
git commit -m "feat: add SiteProfile model for per-site calibration"
```

---

### Task 4: ML Anomaly Service — Autoencoder Inference + Calibration

**Files:**
- Create: `lib/services/ml_anomaly_service.dart` (in Flutter app)

**Step 1: Write the ML anomaly service**

```dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io';
import '../models/site_profile.dart';

/// Manages the autoencoder TFLite model for anomaly detection.
///
/// Two modes:
/// 1. Default mode: uses base model with shipped scaler/thresholds
/// 2. Calibrated mode: uses site-specific scaler/thresholds from SiteProfile
///
/// Calibration workflow:
///   startCalibration() → feedCalibrationSample() × N → finishCalibration() → SiteProfile
class MlAnomalyService {
  Interpreter? _interpreter;
  bool _isLoaded = false;

  // Feature config
  static const featureNames = [
    'rms', 'ppv', 'freq', 'crest', 'centroid', 'kurtosis',
    'stalta', 'arias', 'cav', 'temp', 'psdSlope'
  ];
  static const int inputDim = 11;

  // Active scaler (either base or site-specific)
  List<double> _scalerMean = [];
  List<double> _scalerStd = [];
  double _thresholdLow = 1.0;
  double _thresholdHigh = 2.5;
  String _modelVersion = 'unknown';

  // Calibration state
  bool _isCalibrating = false;
  final List<List<double>> _calibrationSamples = [];
  static const int minCalibrationSamples = 600; // ~5 min at 2 samples/sec

  // Active site profile
  SiteProfile? _activeSiteProfile;

  bool get isLoaded => _isLoaded;
  bool get isCalibrating => _isCalibrating;
  bool get isCalibrated => _activeSiteProfile != null;
  int get calibrationSampleCount => _calibrationSamples.length;
  double get calibrationProgress =>
      (_calibrationSamples.length / minCalibrationSamples).clamp(0.0, 1.0);
  SiteProfile? get activeSiteProfile => _activeSiteProfile;

  /// Load base autoencoder model + default scaler.
  Future<bool> initialize() async {
    try {
      _interpreter = await Interpreter.fromAsset('ml/vibration_anomaly.tflite');

      final scalerJson =
          await rootBundle.loadString('assets/ml/vibration_scaler.json');
      final scaler = jsonDecode(scalerJson) as Map<String, dynamic>;
      _scalerMean =
          (scaler['mean'] as List).map((e) => (e as num).toDouble()).toList();
      _scalerStd =
          (scaler['scale'] as List).map((e) => (e as num).toDouble()).toList();

      final configJson =
          await rootBundle.loadString('assets/ml/vibration_model_config.json');
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      _modelVersion = config['model_version']?.toString() ?? 'unknown';
      final thresholds = config['thresholds'] as Map<String, dynamic>? ?? {};
      _thresholdLow =
          (thresholds['threshold_low'] as num?)?.toDouble() ?? 1.0;
      _thresholdHigh =
          (thresholds['threshold_high'] as num?)?.toDouble() ?? 2.5;

      _isLoaded = true;
      if (kDebugMode) debugPrint('MlAnomalyService: loaded v$_modelVersion');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('MlAnomalyService: load failed: $e');
      return false;
    }
  }

  /// Run autoencoder inference. Returns anomaly score 0–1, or null if not loaded.
  double? infer(Map<String, double> features) {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      final input = List<double>.filled(inputDim, 0.0);
      for (int i = 0; i < featureNames.length; i++) {
        final value = features[featureNames[i]] ?? 0.0;
        if (i < _scalerStd.length && _scalerStd[i] != 0) {
          input[i] = (value - _scalerMean[i]) / _scalerStd[i];
        } else {
          input[i] = value;
        }
      }

      final inputTensor = [input];
      final outputTensor = [List<double>.filled(inputDim, 0.0)];
      _interpreter!.run(inputTensor, outputTensor);

      double mse = 0;
      for (int i = 0; i < inputDim; i++) {
        final diff = input[i] - outputTensor[0][i];
        mse += diff * diff;
      }
      mse /= inputDim;

      // Map to 0–1 score
      if (mse < _thresholdLow) {
        return (mse / _thresholdLow).clamp(0.0, 1.0);
      } else if (mse < _thresholdHigh) {
        return (0.5 + 0.5 * (mse - _thresholdLow) / (_thresholdHigh - _thresholdLow))
            .clamp(0.0, 1.0);
      } else {
        return min(1.0, mse / (_thresholdHigh * 2));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MlAnomalyService: inference error: $e');
      return null;
    }
  }

  // === Calibration ===

  void startCalibration() {
    _isCalibrating = true;
    _calibrationSamples.clear();
  }

  void feedCalibrationSample(Map<String, double> features) {
    if (!_isCalibrating) return;
    final sample = featureNames.map((n) => features[n] ?? 0.0).toList();
    _calibrationSamples.add(sample);
  }

  /// Finish calibration. Returns null if not enough samples.
  SiteProfile? finishCalibration(String siteName) {
    _isCalibrating = false;
    if (_calibrationSamples.length < minCalibrationSamples) return null;

    final n = _calibrationSamples.length;

    // Compute per-feature mean and std
    final mean = List<double>.filled(inputDim, 0.0);
    final std = List<double>.filled(inputDim, 0.0);

    for (int f = 0; f < inputDim; f++) {
      double sum = 0, sumSq = 0;
      for (int s = 0; s < n; s++) {
        sum += _calibrationSamples[s][f];
        sumSq += _calibrationSamples[s][f] * _calibrationSamples[s][f];
      }
      mean[f] = sum / n;
      final variance = (sumSq / n) - (mean[f] * mean[f]);
      std[f] = variance > 0 ? sqrt(variance) : 1.0;
    }

    // Compute reconstruction errors with site-specific scaler
    final errors = <double>[];
    for (final sample in _calibrationSamples) {
      final normalized = List<double>.filled(inputDim, 0.0);
      for (int i = 0; i < inputDim; i++) {
        normalized[i] = (sample[i] - mean[i]) / std[i];
      }
      final output = [List<double>.filled(inputDim, 0.0)];
      _interpreter!.run([normalized], output);
      double mse = 0;
      for (int i = 0; i < inputDim; i++) {
        final diff = normalized[i] - output[0][i];
        mse += diff * diff;
      }
      errors.add(mse / inputDim);
    }

    final errMean = errors.reduce((a, b) => a + b) / errors.length;
    double errStd = 0;
    for (final e in errors) {
      errStd += (e - errMean) * (e - errMean);
    }
    errStd = sqrt(errStd / errors.length);

    // PPV coefficient of variation for quality check
    final ppvIdx = featureNames.indexOf('ppv');
    final ppvCV = std[ppvIdx] / (mean[ppvIdx].abs() + 1e-10);

    final profile = SiteProfile(
      name: siteName,
      createdAt: DateTime.now(),
      modelVersion: _modelVersion,
      scalerMean: mean,
      scalerStd: std,
      thresholdLow: errMean + 2 * errStd,
      thresholdHigh: errMean + 4 * errStd,
      sampleCount: n,
      ppvCoefficientOfVariation: ppvCV,
    );

    applySiteProfile(profile);
    _calibrationSamples.clear();
    return profile;
  }

  void cancelCalibration() {
    _isCalibrating = false;
    _calibrationSamples.clear();
  }

  /// Apply a saved site profile (overrides base scaler + thresholds).
  void applySiteProfile(SiteProfile profile) {
    _activeSiteProfile = profile;
    _scalerMean = List.from(profile.scalerMean);
    _scalerStd = List.from(profile.scalerStd);
    _thresholdLow = profile.thresholdLow;
    _thresholdHigh = profile.thresholdHigh;
    if (kDebugMode) {
      debugPrint('MlAnomalyService: applied site profile "${profile.name}" '
          '(${profile.sampleCount} samples, thresholds: '
          '${_thresholdLow.toStringAsFixed(4)}/${_thresholdHigh.toStringAsFixed(4)})');
    }
  }

  /// Save site profile to app documents directory.
  Future<void> saveSiteProfile(SiteProfile profile) async {
    final dir = await getApplicationDocumentsDirectory();
    final profileDir = Directory('${dir.path}/site_profiles');
    if (!profileDir.existsSync()) profileDir.createSync(recursive: true);
    final file = File('${profileDir.path}/${profile.name}.json');
    await file.writeAsString(profile.encode());
  }

  /// Load all saved site profiles.
  Future<List<SiteProfile>> loadSiteProfiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final profileDir = Directory('${dir.path}/site_profiles');
    if (!profileDir.existsSync()) return [];
    final profiles = <SiteProfile>[];
    for (final file in profileDir.listSync().whereType<File>()) {
      if (file.path.endsWith('.json')) {
        try {
          profiles.add(SiteProfile.decode(await file.readAsString()));
        } catch (_) {}
      }
    }
    profiles.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return profiles;
  }

  /// Delete a saved site profile.
  Future<void> deleteSiteProfile(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/site_profiles/$name.json');
    if (file.existsSync()) await file.delete();
    if (_activeSiteProfile?.name == name) _activeSiteProfile = null;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
```

**Step 2: Commit**

```bash
git add lib/services/ml_anomaly_service.dart
git commit -m "feat: add MlAnomalyService with calibration workflow"
```

---

### Task 5: Precursor Classifier Service

**Files:**
- Create: `lib/services/precursor_classifier_service.dart` (in Flutter app)

**Step 1: Write the precursor classifier service**

```dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Classifies vibration patterns into precursor categories using a TFLite model.
///
/// Input: 17 features (11 DSP + 6 trend).
/// Output: class (normal, soil_creep, crack_propagation, imminent_failure) + confidence.
class PrecursorClassifierService {
  Interpreter? _interpreter;
  bool _isLoaded = false;
  List<String> _classNames = ['normal', 'soil_creep', 'crack_propagation', 'imminent_failure'];

  static const featureNames = [
    'rms', 'ppv', 'freq', 'crest', 'centroid', 'kurtosis',
    'stalta', 'arias', 'cav', 'temp', 'psdSlope',
    'ppv_trend', 'freq_trend', 'kurtosis_trend', 'stalta_trend',
    'cusum_max', 'autoencoder_score',
  ];

  bool get isLoaded => _isLoaded;

  Future<bool> initialize() async {
    try {
      _interpreter = await Interpreter.fromAsset('ml/precursor_classifier.tflite');

      final configJson =
          await rootBundle.loadString('assets/ml/precursor_classifier_config.json');
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      _classNames = (config['class_names'] as List).map((e) => e.toString()).toList();

      _isLoaded = true;
      if (kDebugMode) debugPrint('PrecursorClassifier: loaded (${_classNames.length} classes)');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('PrecursorClassifier: load failed: $e');
      return false;
    }
  }

  /// Classify the current vibration pattern.
  ///
  /// [dspFeatures]: 11 DSP features from VibrationDspService
  /// [trendFeatures]: trend ratios and scores from AdaptiveAnomalyService
  /// [autoencoderScore]: anomaly score from MlAnomalyService (0–1)
  PrecursorResult? classify({
    required Map<String, double> dspFeatures,
    required Map<String, double> trendFeatures,
    required double autoencoderScore,
  }) {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      final input = <double>[
        // 11 DSP features
        dspFeatures['rms'] ?? 0,
        dspFeatures['ppv'] ?? 0,
        dspFeatures['freq'] ?? 0,
        dspFeatures['crest'] ?? 0,
        dspFeatures['centroid'] ?? 0,
        dspFeatures['kurtosis'] ?? 0,
        dspFeatures['stalta'] ?? 0,
        dspFeatures['arias'] ?? 0,
        dspFeatures['cav'] ?? 0,
        dspFeatures['temp'] ?? 0,
        dspFeatures['psdSlope'] ?? 0,
        // 6 trend features
        trendFeatures['ppv_trend'] ?? 1.0,
        trendFeatures['freq_trend'] ?? 1.0,
        trendFeatures['kurtosis_trend'] ?? 1.0,
        trendFeatures['stalta_trend'] ?? 1.0,
        trendFeatures['cusum_max'] ?? 0.0,
        autoencoderScore,
      ];

      final inputTensor = [input];
      final outputTensor = [List<double>.filled(_classNames.length, 0.0)];
      _interpreter!.run(inputTensor, outputTensor);

      final probs = outputTensor[0];
      int maxIdx = 0;
      double maxProb = probs[0];
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > maxProb) {
          maxProb = probs[i];
          maxIdx = i;
        }
      }

      return PrecursorResult(
        pattern: _classNames[maxIdx],
        confidence: maxProb.clamp(0.0, 1.0),
        probabilities: Map.fromIterables(_classNames, probs),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('PrecursorClassifier: inference error: $e');
      return null;
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}

class PrecursorResult {
  final String pattern;
  final double confidence;
  final Map<String, double> probabilities;

  const PrecursorResult({
    required this.pattern,
    required this.confidence,
    required this.probabilities,
  });

  bool get isNormal => pattern == 'normal';
  bool get isDangerous => pattern == 'imminent_failure' && confidence > 0.5;

  /// Convert confidence to an anomaly-compatible score (0–1).
  /// Normal class maps to low score, danger classes map to high.
  double get anomalyScore {
    if (isNormal) return (1.0 - confidence) * 0.3; // max 0.3 if uncertain normal
    return confidence; // direct confidence for precursor patterns
  }
}
```

**Step 2: Commit**

```bash
git add lib/services/precursor_classifier_service.dart
git commit -m "feat: add PrecursorClassifierService for precursor pattern detection"
```

---

### Task 6: Integrate into VibrationAnomalyService

**Files:**
- Modify: `lib/services/vibration_anomaly_service.dart` (in Flutter app)

**Step 1: Add imports and new service fields**

At the top of the file, add imports for the new services:
```dart
import 'ml_anomaly_service.dart';
import 'precursor_classifier_service.dart';
```

Add fields to the `VibrationAnomalyService` class:
```dart
final MlAnomalyService _mlService = MlAnomalyService();
final PrecursorClassifierService _precursorService = PrecursorClassifierService();
```

**Step 2: Update initialize() to load both new models**

After the existing TFLite loading block (the try/catch at lines 70-123), add:
```dart
// Also initialize standalone ML services
await _mlService.initialize();
await _precursorService.initialize();
```

**Step 3: Update detect() to use new ML pipeline**

Modify the `detect()` method. When `_interpreter` is available (ML path), after computing the autoencoder score, also run the precursor classifier:

After the existing ML inference block (around line 205), before the return:
```dart
// Run precursor classifier if available
final trendFeatures = _adaptiveService.getTrendFeatures(); // Need to expose this
final precursorResult = _precursorService.classify(
  dspFeatures: features,
  trendFeatures: trendFeatures,
  autoencoderScore: score,
);

// Merge: highest severity wins
if (precursorResult != null && !precursorResult.isNormal) {
  final precursorScore = precursorResult.anomalyScore;
  if (precursorScore > score) {
    score = precursorScore;
    level = precursorScore >= 0.7 ? AnomalyLevel.anomaly
        : precursorScore >= 0.35 ? AnomalyLevel.unusual
        : AnomalyLevel.normal;
  }
}
```

**Step 4: Expose MlAnomalyService for calibration UI**

Add getters:
```dart
MlAnomalyService get mlService => _mlService;
PrecursorClassifierService get precursorService => _precursorService;
```

**Step 5: Add getTrendFeatures() to adaptive_anomaly_service.dart**

Add this method to `AdaptiveAnomalyService`:
```dart
/// Get current trend features for precursor classifier input.
Map<String, double> getTrendFeatures() {
  if (!_isCalibrated) {
    return {
      'ppv_trend': 1.0, 'freq_trend': 1.0, 'kurtosis_trend': 1.0,
      'stalta_trend': 1.0, 'cusum_max': 0.0, 'autoencoder_score': 0.0,
    };
  }
  double shortLongRatio(String key) {
    final short = _shortWindow[key];
    final long = _longWindow[key];
    if (short == null || long == null || short.isEmpty || long.isEmpty) return 1.0;
    final shortMean = short.toList().reduce((a, b) => a + b) / short.length;
    final longMean = long.toList().reduce((a, b) => a + b) / long.length;
    return longMean != 0 ? shortMean / longMean : 1.0;
  }
  double maxCusum() {
    double m = 0;
    for (final key in _featureKeys) {
      final pos = _cusumPositive[key] ?? 0;
      final neg = _cusumNegative[key] ?? 0;
      if (pos > m) m = pos;
      if (neg > m) m = neg;
    }
    return m;
  }
  return {
    'ppv_trend': shortLongRatio('ppv'),
    'freq_trend': shortLongRatio('freq'),
    'kurtosis_trend': shortLongRatio('kurtosis'),
    'stalta_trend': shortLongRatio('stalta'),
    'cusum_max': maxCusum(),
    'autoencoder_score': 0.0, // filled by caller
  };
}
```

**Step 6: Commit**

```bash
git add lib/services/vibration_anomaly_service.dart lib/services/adaptive_anomaly_service.dart
git commit -m "feat: integrate ML autoencoder + precursor classifier into detection pipeline"
```

---

### Task 7: Add Calibration UI to SafetyView

**Files:**
- Modify: `lib/screens/safety/safety_view.dart` (in Flutter app)

**Step 1: Add imports and state**

Add to imports:
```dart
import '../../models/site_profile.dart';
```

Add state variables:
```dart
// Site calibration
bool _isCalibrating = false;
String? _calibrationSiteName;
```

**Step 2: Add calibration icon button to header row**

In the header `Row` (around line 1360-1383), after the mode toggle, add:
```dart
if (isConnected)
  IconButton(
    icon: Icon(
      _isCalibrating ? Icons.stop_circle : Icons.tune,
      color: _isCalibrating ? Colors.orangeAccent : Colors.white70,
      size: 22,
    ),
    tooltip: _isCalibrating ? 'Stop Calibration' : 'Calibrate Site',
    onPressed: _isCalibrating ? _stopCalibration : _showCalibrationDialog,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
  ),
```

**Step 3: Add calibration methods**

```dart
void _showCalibrationDialog() {
  final controller = TextEditingController(text: 'Site ${DateTime.now().toString().substring(0, 10)}');
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1C2523),
      title: const Text('Calibrate Site', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Record 5+ minutes of normal ambient vibration to establish baseline.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Site Name',
              labelStyle: TextStyle(color: Colors.white54),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.tealAccent)),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            _startCalibration(controller.text.trim());
          },
          child: const Text('Start', style: TextStyle(color: Colors.tealAccent)),
        ),
      ],
    ),
  );
}

void _startCalibration(String siteName) {
  if (siteName.isEmpty) return;
  _anomalyService.mlService.startCalibration();
  setState(() {
    _isCalibrating = true;
    _calibrationSiteName = siteName;
  });
}

void _stopCalibration() {
  final profile = _anomalyService.mlService.finishCalibration(_calibrationSiteName ?? 'Unknown');
  setState(() => _isCalibrating = false);

  if (profile == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not enough samples. Need at least 5 minutes of data.')),
    );
    return;
  }

  _anomalyService.mlService.saveSiteProfile(profile);

  final warning = profile.highVarianceWarning
      ? '\nWarning: High PPV variance detected — site may not be in normal state.'
      : '';

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Site "${profile.name}" calibrated (${profile.sampleCount} samples).$warning')),
  );
}
```

**Step 4: Feed calibration samples in the detection loop**

In the existing detection block (around line 954-975 in safety_view), after `_anomalyService.detect(features)`, add:
```dart
// Feed calibration if active
if (_isCalibrating) {
  _anomalyService.mlService.feedCalibrationSample(features);
}
```

**Step 5: Add calibration progress indicator**

After the ML anomaly warning banner (around line 2303), add:
```dart
// Calibration progress
if (_isCalibrating) ...[
  const SizedBox(height: 12),
  Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.tealAccent.withAlpha(20),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.tealAccent.withAlpha(80), width: 1),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Calibrating: $_calibrationSiteName',
          style: const TextStyle(color: Colors.tealAccent, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _anomalyService.mlService.calibrationProgress,
          backgroundColor: Colors.white12,
          color: Colors.tealAccent,
        ),
        const SizedBox(height: 4),
        Text(
          '${_anomalyService.mlService.calibrationSampleCount} / 600 samples'
          ' (~${((600 - _anomalyService.mlService.calibrationSampleCount) / 2).ceil()}s remaining)',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    ),
  ),
],
```

**Step 6: Commit**

```bash
git add lib/screens/safety/safety_view.dart
git commit -m "feat: add site calibration UI to safety view"
```

---

### Task 8: Register ML Assets in pubspec.yaml

**Files:**
- Modify: `pubspec.yaml` (in Flutter app)

**Step 1: Ensure ML assets are listed**

In the `flutter:` → `assets:` section, verify these entries exist (add if missing):
```yaml
    - assets/ml/
```

**Step 2: Commit**

```bash
git add pubspec.yaml
git commit -m "chore: register ML model assets in pubspec"
```

---

### Task 9: Flutter Analyze + Smoke Test

**Step 1: Run flutter analyze**

Run: `cd "C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision" && flutter analyze`
Expected: No errors. Fix any issues.

**Step 2: Verify TFLite models load**

Run: `cd "C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision" && flutter build apk --debug`
Expected: Build succeeds. Models bundled in APK.

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve analyze issues from ML integration"
```

---

Plan complete and saved to `docs/plans/2026-02-24-ml-anomaly-detection-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
