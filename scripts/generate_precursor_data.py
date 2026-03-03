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

import json
import os

import numpy as np
from sklearn.tree import DecisionTreeClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report

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
    elif name == "soil_creep":
        return np.column_stack([
            _uniform(0.1, 0.8, n),     # rms
            _uniform(0.3, 2.0, n),     # ppv
            _uniform(2, 20, n),        # freq  (dropping)
            _uniform(2.0, 5.0, n),     # crest
            _uniform(3, 25, n),        # centroid
            _uniform(1.0, 6.0, n),     # kurtosis (rising)
            _uniform(1.0, 3.0, n),     # stalta
            _uniform(0.02, 0.3, n),    # arias
            _uniform(0.1, 1.0, n),     # cav
            _uniform(15, 35, n),       # temp
            _uniform(-4, -1, n),       # psdSlope
            _uniform(1.1, 1.6, n),     # ppv_trend >1.1
            _uniform(0.5, 0.9, n),     # freq_trend <0.9
            _uniform(1.1, 1.5, n),     # kurtosis_trend >1.1
            _uniform(0.9, 1.3, n),     # stalta_trend
            _uniform(0.3, 2.0, n),     # cusum_max
            _uniform(0.1, 0.6, n),     # autoencoder_score
        ])
    elif name == "crack_propagation":
        return np.column_stack([
            _uniform(0.2, 1.5, n),     # rms
            _uniform(0.5, 4.0, n),     # ppv
            _uniform(5, 40, n),        # freq
            _uniform(4.0, 12.0, n),    # crest HIGH
            _uniform(10, 50, n),       # centroid
            _uniform(3.0, 12.0, n),    # kurtosis HIGH
            _uniform(2.0, 8.0, n),     # stalta HIGH
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
            _uniform(0.5, 5.0, n),     # rms
            _uniform(1.0, 10.0, n),    # ppv VERY HIGH
            _uniform(1, 8, n),         # freq LOW
            _uniform(4.0, 15.0, n),    # crest
            _uniform(2, 15, n),        # centroid
            _uniform(4.0, 15.0, n),    # kurtosis
            _uniform(3.0, 12.0, n),    # stalta
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
    raise ValueError(f"Unknown class: {name}")


samples = {
    "normal": 3000,
    "soil_creep": 2000,
    "crack_propagation": 2000,
    "imminent_failure": 1500,
}

X_parts, y_parts = [], []
for i, (cls, n) in enumerate(samples.items()):
    X_parts.append(generate_class(cls, n))
    y_parts.append(np.full(n, i, dtype=np.int32))

X = np.vstack(X_parts).astype(np.float32)
y = np.concatenate(y_parts)

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42, stratify=y
)

print(f"Dataset: {X.shape[0]} samples, {X.shape[1]} features, {len(CLASS_NAMES)} classes")
print(f"Train: {X_train.shape[0]}, Test: {X_test.shape[0]}")

# ---------------------------------------------------------------------------
# 2. Reference: Decision Tree
# ---------------------------------------------------------------------------

dt = DecisionTreeClassifier(random_state=42, max_depth=10)
dt.fit(X_train, y_train)
dt_acc = dt.score(X_test, y_test)
print(f"\nDecision Tree accuracy: {dt_acc:.4f}")
print(classification_report(y_test, dt.predict(X_test), target_names=CLASS_NAMES))

# ---------------------------------------------------------------------------
# 3. Neural net (TFLite-exportable)
# ---------------------------------------------------------------------------

import tensorflow as tf
tf.random.set_seed(42)

model = tf.keras.Sequential([
    tf.keras.layers.Input(shape=(17,)),
    tf.keras.layers.Dense(16, activation="relu"),
    tf.keras.layers.Dense(8, activation="relu"),
    tf.keras.layers.Dense(4, activation="softmax"),
])

model.compile(
    optimizer="adam",
    loss="sparse_categorical_crossentropy",
    metrics=["accuracy"],
)

model.fit(
    X_train, y_train,
    validation_data=(X_test, y_test),
    epochs=50,
    batch_size=64,
    verbose=1,
)

nn_loss, nn_acc = model.evaluate(X_test, y_test, verbose=0)
print(f"\nNeural net accuracy: {nn_acc:.4f}")
y_pred_nn = np.argmax(model.predict(X_test, verbose=0), axis=1)
print(classification_report(y_test, y_pred_nn, target_names=CLASS_NAMES))

# ---------------------------------------------------------------------------
# 4. Export to TFLite
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
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

# Verify TFLite inference
interpreter = tf.lite.Interpreter(model_path=tflite_path)
interpreter.allocate_tensors()
inp = interpreter.get_input_details()
out = interpreter.get_output_details()
interpreter.set_tensor(inp[0]["index"], X_test[:1])
interpreter.invoke()
prob = interpreter.get_tensor(out[0]["index"])[0]
print(f"TFLite verification — sample 0 probs: {prob}, predicted: {CLASS_NAMES[np.argmax(prob)]}")

# Config JSON
# Export scaler (mean/std from training data) for runtime normalization
scaler_mean = X_train.mean(axis=0).tolist()
scaler_std = X_train.std(axis=0).tolist()
# Avoid division by zero
scaler_std = [s if s > 1e-10 else 1.0 for s in scaler_std]

scaler = {
    "mean": scaler_mean,
    "scale": scaler_std,
    "feature_names": FEATURE_NAMES,
}
scaler_path = os.path.join(ASSETS_DIR, "precursor_classifier_scaler.json")
with open(scaler_path, "w") as f:
    json.dump(scaler, f, indent=2)
print(f"Scaler: {scaler_path}")

config = {
    "model_version": "1.0.0",
    "model_file": "precursor_classifier.tflite",
    "feature_names": FEATURE_NAMES,
    "class_names": CLASS_NAMES,
    "input_dim": 17,
    "output_dim": 4,
}
config_path = os.path.join(ASSETS_DIR, "precursor_classifier_config.json")
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"Config: {config_path}")

print("\nDone.")
