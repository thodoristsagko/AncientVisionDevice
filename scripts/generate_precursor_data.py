#!/usr/bin/env python3
"""Generate synthetic precursor vibration data and train a TFLite classifier.

Classes (from geotechnical literature):
  0 - normal: ambient baseline
  1 - soil_creep: slow deformation, PPV elevated, freq dropping
  2 - crack_propagation: impulsive, high crest/kurtosis/STA-LTA
  3 - imminent_failure: strong across all metrics

17 features: 11 DSP + 6 trend.
Model: 17 -> 16 -> 8 -> 4 (softmax), exported to TFLite.
"""

import datetime
import json
import os
import subprocess
import sys as _sys

import numpy as np
import tensorflow as tf
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.model_selection import StratifiedKFold, cross_val_score, train_test_split
from sklearn.tree import DecisionTreeClassifier
from sklearn.utils.class_weight import compute_class_weight

np.random.seed(42)

# ---------------------------------------------------------------------------
# 1. Synthetic data generation
# ---------------------------------------------------------------------------

FEATURE_NAMES = [
    "rms", "ppv", "freq", "crest", "centroid", "kurtosis", "stalta",
    "arias", "cav", "temp", "psdSlope",
    "ppv_trend", "freq_trend", "kurtosis_trend", "stalta_trend",
    "cusum_max", "autoencoder_score",
]
CLASS_NAMES = ["normal", "soil_creep", "crack_propagation", "imminent_failure"]


def _uniform(lo, hi, n):
    return np.random.uniform(lo, hi, n)


def generate_class(name: str, n: int) -> np.ndarray:
    """Return (n, 17) array for one class."""
    if name == "normal":
        return np.column_stack([
            _uniform(0.01, 0.15, n),   # rms
            _uniform(0.01, 0.25, n),   # ppv
            _uniform(5, 80, n),        # freq
            _uniform(1.5, 3.5, n),     # crest
            _uniform(10, 60, n),       # centroid
            _uniform(0.5, 3.0, n),     # kurtosis
            _uniform(0.5, 1.5, n),     # stalta
            _uniform(0.0, 0.05, n),    # arias
            _uniform(0.0, 0.3, n),     # cav
            _uniform(15, 35, n),       # temp
            _uniform(-3, -0.5, n),     # psdSlope
            _uniform(0.9, 1.1, n),     # ppv_trend
            _uniform(0.9, 1.1, n),     # freq_trend
            _uniform(0.9, 1.1, n),     # kurtosis_trend
            _uniform(0.9, 1.1, n),     # stalta_trend
            _uniform(0.0, 0.5, n),     # cusum_max
            _uniform(0.0, 0.3, n),     # autoencoder_score
        ])
    elif name == "normal_human_activity":
        # Footsteps/tools: high freq, very low PPV, short-duration high crest, low kurtosis
        return np.column_stack([
            _uniform(0.005, 0.04, n),  # rms very low
            _uniform(0.001, 0.05, n),  # ppv very low
            _uniform(30, 80, n),       # freq high (footstep/tool impact)
            _uniform(6.0, 9.0, n),     # crest HIGH (impulsive but short)
            _uniform(30, 70, n),       # centroid high-freq
            _uniform(0.5, 2.5, n),     # kurtosis LOW (not geotechnical impulsive)
            _uniform(0.5, 1.5, n),     # stalta low (no sustained trigger)
            _uniform(0.0, 0.01, n),    # arias very low
            _uniform(0.0, 0.05, n),    # cav very low
            _uniform(15, 35, n),       # temp
            _uniform(-2, 0.5, n),      # psdSlope (flatter, high-freq dominated)
            _uniform(0.9, 1.1, n),     # ppv_trend stable
            _uniform(0.9, 1.1, n),     # freq_trend stable
            _uniform(0.9, 1.1, n),     # kurtosis_trend stable
            _uniform(0.9, 1.1, n),     # stalta_trend stable
            _uniform(0.0, 0.3, n),     # cusum_max low
            _uniform(0.0, 0.2, n),     # autoencoder_score low
        ])
    elif name == "soil_creep":
        # Trend correlation: ppv_trend and kurtosis_trend both rise together
        corr_factor = np.random.uniform(0, 0.8, n)
        ppv_trend = np.random.uniform(0, 1, n) * 0.7 + 0.8 + corr_factor   # 0.8+corr to 1.5+corr
        kurtosis_trend = np.random.uniform(0, 1, n) * 0.7 + 0.8 + corr_factor
        return np.column_stack([
            _uniform(0.1, 0.8, n),     # rms
            _uniform(0.3, 2.0, n),     # ppv (was 0.2-0.8)
            _uniform(3.0, 20.0, n),    # freq slowly dropping (was 5-30)
            _uniform(2.0, 5.0, n),     # crest
            _uniform(3, 25, n),        # centroid
            _uniform(1.0, 6.0, n),     # kurtosis (rising)
            _uniform(2.0, 8.0, n),     # stalta (was 1.5-5.0)
            _uniform(0.02, 0.3, n),    # arias
            _uniform(0.1, 1.0, n),     # cav
            _uniform(15, 35, n),       # temp
            _uniform(-4, -1, n),       # psdSlope
            ppv_trend,                 # ppv_trend correlated with kurtosis_trend
            _uniform(0.5, 0.9, n),     # freq_trend <0.9
            kurtosis_trend,            # kurtosis_trend correlated with ppv_trend
            _uniform(0.9, 1.3, n),     # stalta_trend
            _uniform(0.3, 2.0, n),     # cusum_max
            _uniform(0.1, 0.6, n),     # autoencoder_score
        ])
    elif name == "crack_propagation":
        return np.column_stack([
            _uniform(0.2, 1.5, n),     # rms
            _uniform(0.5, 3.0, n),     # ppv (was 0.3-1.5)
            _uniform(5, 40, n),        # freq
            _uniform(8.0, 20.0, n),    # crest HIGH impulsive (was 4.0-12.0)
            _uniform(10, 50, n),       # centroid
            _uniform(6.0, 15.0, n),    # kurtosis clearly impulsive (was 2.0-8.0)
            _uniform(5.0, 12.0, n),    # stalta HIGH (was 2.0-8.0)
            _uniform(0.05, 0.8, n),    # arias
            _uniform(0.3, 2.5, n),     # cav
            _uniform(15, 35, n),       # temp
            _uniform(-5, -1.5, n),     # psdSlope
            _uniform(1.0, 1.5, n),     # ppv_trend
            _uniform(0.7, 1.1, n),     # freq_trend
            _uniform(1.2, 2.0, n),     # kurtosis_trend >1.2
            _uniform(1.2, 2.0, n),     # stalta_trend >1.2
            _uniform(0.5, 3.0, n),     # cusum_max
            _uniform(0.2, 0.8, n),     # autoencoder_score
        ])
    elif name == "imminent_failure":
        return np.column_stack([
            _uniform(1.0, 5.0, n),     # rms (was 0.5-3.0)
            _uniform(2.0, 8.0, n),     # ppv VERY HIGH (was 1.0-5.0)
            _uniform(0.5, 5.0, n),     # freq deep low-freq collapse (was 1-10)
            _uniform(4.0, 15.0, n),    # crest
            _uniform(2, 15, n),        # centroid
            _uniform(10.0, 20.0, n),   # kurtosis (was 5.0-15.0)
            _uniform(8.0, 15.0, n),    # stalta (was 5.0-12.0)
            _uniform(0.2, 3.0, n),     # arias
            _uniform(1.0, 8.0, n),     # cav
            _uniform(15, 35, n),       # temp
            _uniform(-6, -2, n),       # psdSlope
            _uniform(1.3, 2.5, n),     # ppv_trend strongly rising
            _uniform(0.3, 0.8, n),     # freq_trend strongly dropping
            _uniform(1.3, 2.5, n),     # kurtosis_trend
            _uniform(1.3, 2.5, n),     # stalta_trend
            _uniform(2.0, 10.0, n),    # cusum_max very high
            _uniform(0.5, 1.0, n),     # autoencoder_score
        ])
    else:
        raise ValueError(f"Unknown class: {name}")


samples = {
    "normal": 3200,          # 3200 baseline + 400 human_activity = 3600 total
    "soil_creep": 2400,
    "crack_propagation": 2400,
    "imminent_failure": 1800,
}

X_parts, y_parts = [], []
for i, (cls, n) in enumerate(samples.items()):
    X_parts.append(generate_class(cls, n))
    y_parts.append(np.full(n, i, dtype=np.int32))

# Append 400 "human activity" samples as label=0 (normal)
_human_n = 400
X_parts.append(generate_class("normal_human_activity", _human_n))
y_parts.append(np.full(_human_n, 0, dtype=np.int32))  # label 0 = normal

X = np.vstack(X_parts).astype(np.float32)
y = np.concatenate(y_parts)

print(f"Dataset: {X.shape[0]} samples, {X.shape[1]} features, {len(CLASS_NAMES)} classes")

# ---------------------------------------------------------------------------
# 2. Scale full dataset (needed for CV and holdout splits)
# ---------------------------------------------------------------------------

# Compute scaler on full dataset first (used for CV on decision tree and holdout eval)
X_mean_full = X.mean(axis=0)
X_std_full = X.std(axis=0)
X_std_full = np.where(X_std_full > 1e-10, X_std_full, 1.0)
X_scaled = ((X - X_mean_full) / X_std_full).astype(np.float32)

# ---------------------------------------------------------------------------
# P17: Carve out stratified 15% holdout BEFORE any train/val split
# ---------------------------------------------------------------------------

X_trainval, X_holdout, y_trainval, y_holdout = train_test_split(
    X_scaled, y, test_size=0.15, stratify=y, random_state=42
)
print(f"TrainVal: {X_trainval.shape[0]}, Holdout: {X_holdout.shape[0]}")

# ---------------------------------------------------------------------------
# 3. Reference: Decision Tree (trained on trainval portion)
# ---------------------------------------------------------------------------

dt = DecisionTreeClassifier(random_state=42, max_depth=10)
dt.fit(X_trainval, y_trainval)
dt_acc = dt.score(X_holdout, y_holdout)
print(f"\nDecision Tree accuracy (holdout): {dt_acc:.4f}")
print(classification_report(y_holdout, dt.predict(X_holdout), target_names=CLASS_NAMES))

# ---------------------------------------------------------------------------
# P13: 5-fold cross-validation on decision tree
# ---------------------------------------------------------------------------

clf = DecisionTreeClassifier(random_state=42, max_depth=10)
skf = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
cv_scores = cross_val_score(clf, X_scaled, y, cv=skf, scoring='accuracy')
print(f"[CV] Decision tree 5-fold accuracy: {cv_scores.mean():.3f} ± {cv_scores.std():.3f}")
print(f"[CV] Per-fold: {[round(s, 3) for s in cv_scores]}")

# ---------------------------------------------------------------------------
# 4. Neural net (TFLite-exportable)
# ---------------------------------------------------------------------------

tf.random.set_seed(42)

# P21: Compute class weights for imbalanced training set
class_weights_arr = compute_class_weight('balanced', classes=np.unique(y_trainval), y=y_trainval)
class_weight_dict = dict(enumerate(class_weights_arr))
print(f"\n[CLASS WEIGHTS] {class_weight_dict}")

# P16: L2 regularization on dense layers
model = tf.keras.Sequential([
    tf.keras.layers.Input(shape=(17,)),
    tf.keras.layers.Dense(16, activation="relu",
        kernel_regularizer=tf.keras.regularizers.l2(0.001)),
    tf.keras.layers.Dense(8, activation="relu",
        kernel_regularizer=tf.keras.regularizers.l2(0.001)),
    tf.keras.layers.Dense(4, activation="softmax"),
])

model.compile(
    optimizer="adam",
    loss="sparse_categorical_crossentropy",
    metrics=["accuracy"],
)

# P15: Early stopping callback
early_stop = tf.keras.callbacks.EarlyStopping(
    monitor='val_loss', patience=10, restore_best_weights=True, verbose=1
)

model.fit(
    X_trainval, y_trainval,
    validation_split=0.15,   # P15: changed from 0.2 to keep more for training
    epochs=50,
    batch_size=64,
    verbose=1,
    callbacks=[early_stop],  # P15: early stopping
    class_weight=class_weight_dict,  # P21: class weight balancing
)

nn_loss, nn_acc = model.evaluate(X_holdout, y_holdout, verbose=0)
print(f"\nNeural net accuracy (holdout): {nn_acc:.4f}")

# ---------------------------------------------------------------------------
# P14: Confusion matrix + F1 metrics
# ---------------------------------------------------------------------------

test_pred_probs = model.predict(X_holdout, verbose=0)
test_pred = np.argmax(test_pred_probs, axis=1)
test_true = y_holdout

cm = confusion_matrix(test_true, test_pred)
class_names_short = ['normal', 'soil_cr', 'crack_p', 'imm_f']
print("\n[METRICS] Confusion matrix (rows=true, cols=pred):")
print(f"         {' '.join(f'{n:>8}' for n in class_names_short)}")
for i, row in enumerate(cm):
    print(f"  {class_names_short[i]:>8} {' '.join(f'{v:>8}' for v in row)}")

report = classification_report(test_true, test_pred, target_names=CLASS_NAMES)
print(f"\n[METRICS] Classification report:\n{report}")

# ---------------------------------------------------------------------------
# P17: Evaluate on holdout set
# ---------------------------------------------------------------------------

holdout_acc = float(nn_acc)
print(f"[HOLDOUT] Accuracy on unseen data: {holdout_acc:.3f} ({len(X_holdout)} samples)")

# ---------------------------------------------------------------------------
# 5. Export to TFLite
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
REPO = PROJECT_DIR
# In Docker: /workspace/app/assets/ml  (mounted from ./app/assets/ml)
# On Windows host: <repo>/app/assets/ml
ASSETS_DIR = os.path.join(PROJECT_DIR, "app", "assets", "ml")
os.makedirs(ASSETS_DIR, exist_ok=True)

converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite_model = converter.convert()

tflite_path = os.path.join(ASSETS_DIR, "precursor_classifier.tflite")
with open(tflite_path, "wb") as f:
    f.write(tflite_model)

size_kb = len(tflite_model) / 1024
print(f"\nTFLite model: {size_kb:.1f} KB -> {tflite_path}")

# Verify TFLite inference — run in subprocess to avoid segfault (exit 139)
# that occurs when tf.lite.Interpreter is called in-process inside Docker.
_result = subprocess.run(
    [_sys.executable, "-c",
     f"import tensorflow as tf; "
     f"i=tf.lite.Interpreter(model_path=r'{tflite_path}'); "
     f"i.allocate_tensors()"],
    capture_output=True
)
if _result.returncode != 0:
    raise RuntimeError(f"TFLite verification failed: {_result.stderr.decode()}")
print("TFLite verification passed.")

# Config JSON
# Export scaler (mean/std from training data) for runtime normalization
# Use trainval portion only so holdout remains truly unseen
scaler_mean = X_trainval.mean(axis=0).tolist()
scaler_std_vals = X_trainval.std(axis=0)
scaler_std_vals = np.where(scaler_std_vals > 1e-10, scaler_std_vals, 1.0)
scaler_std = scaler_std_vals.tolist()

scaler = {
    "mean": scaler_mean,
    "scale": scaler_std,
    "feature_names": FEATURE_NAMES,
}
scaler_path = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
with open(scaler_path, "w") as f:
    json.dump(scaler, f, indent=2)
print(f"Scaler: {scaler_path}")

# ---------------------------------------------------------------------------
# P18: Model versioning in config JSON
# ---------------------------------------------------------------------------

try:
    git_sha = subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=REPO,
        capture_output=True,
        text=True,
    ).stdout.strip()
except Exception:
    git_sha = "unknown"

config = {
    "model_version": "1.0.0",
    "model_file": "precursor_classifier.tflite",
    "feature_names": FEATURE_NAMES,
    "class_names": CLASS_NAMES,
    "input_dim": 17,
    "output_dim": 4,
    "trained_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "git_sha": git_sha,
    "total_samples": int(len(X)),
    "holdout_accuracy": holdout_acc,
    "cv_mean_accuracy": float(cv_scores.mean()),
}
config_path = os.path.join(ASSETS_DIR, "precursor_classifier_config.json")
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"Config: {config_path}")

# ---------------------------------------------------------------------------
# P22: Training metrics JSON output
# ---------------------------------------------------------------------------

metrics_path = os.path.join(ASSETS_DIR, "precursor_training_metrics.json")
metrics = {
    "trained_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "total_samples": int(len(X)),
    "class_distribution": {name: int(np.sum(y == i)) for i, name in enumerate(CLASS_NAMES)},
    "cv_accuracy_mean": float(cv_scores.mean()),
    "cv_accuracy_std": float(cv_scores.std()),
    "holdout_accuracy": holdout_acc,
    "model_size_bytes": int(os.path.getsize(tflite_path)),
}
with open(metrics_path, "w") as f:
    json.dump(metrics, f, indent=2)
print(f"[METRICS] Written to {metrics_path}")

print("\nDone.")
