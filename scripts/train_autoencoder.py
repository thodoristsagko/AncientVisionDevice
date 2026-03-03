"""
Train base autoencoder for vibration anomaly detection.
Generates synthetic 'normal' vibration data, trains 11→8→4→8→11 autoencoder,
exports TFLite model + scaler/config JSON to both firmware and Flutter asset dirs.
"""

import json
import os
import random

import numpy as np
import tensorflow as tf
from sklearn.preprocessing import StandardScaler

# P132: Fix random seeds for reproducibility
random.seed(42)
np.random.seed(42)
tf.random.set_seed(42)
print("Random seed fixed: 42")

N_SAMPLES = 10000

# Feature ranges: (name, low, high)
FEATURES = [
    ("rms",      0.001, 0.05),
    ("ppv",      0.01,  0.3),
    ("freq",     5.0,   50.0),
    ("crest",    2.0,   6.0),
    ("centroid", 10.0,  40.0),
    ("kurtosis", -1.0,  3.0),
    ("stalta",   0.5,   2.0),
    ("arias",    0.0,   0.001),
    ("cav",      0.0,   0.01),
    ("temp",     15.0,  35.0),
    ("psdSlope", -12.0, -6.0),
]

feature_names = [f[0] for f in FEATURES]
n_features = len(FEATURES)

# Generate truncated-normal data centered in each range
data = np.zeros((N_SAMPLES, n_features), dtype=np.float32)
for i, (name, lo, hi) in enumerate(FEATURES):
    mu = (lo + hi) / 2.0
    sigma = (hi - lo) / 4.0  # ~95% within range
    col = np.random.normal(mu, sigma, N_SAMPLES).astype(np.float32)
    col = np.clip(col, lo, hi)
    data[:, i] = col

# Normalize
scaler = StandardScaler()
data_scaled = scaler.fit_transform(data).astype(np.float32)

# Build autoencoder
model = tf.keras.Sequential([
    tf.keras.layers.InputLayer(shape=(n_features,)),
    tf.keras.layers.Dense(8, activation="relu"),
    tf.keras.layers.Dense(4, activation="relu"),
    tf.keras.layers.Dense(8, activation="relu"),
    tf.keras.layers.Dense(n_features, activation="linear"),
])
model.compile(optimizer="adam", loss="mse")
model.summary()

# P23: Early stopping + LR schedule callbacks
callbacks = [
    tf.keras.callbacks.EarlyStopping(
        monitor='val_loss', patience=15, restore_best_weights=True, verbose=1
    ),
    tf.keras.callbacks.ReduceLROnPlateau(
        monitor='val_loss', factor=0.5, patience=5, min_lr=1e-5, verbose=1
    ),
]

# Train
model.fit(
    data_scaled, data_scaled,
    epochs=100,
    batch_size=64,
    validation_split=0.1,
    verbose=1,
    callbacks=callbacks,
)

# Compute reconstruction error thresholds
preds = model.predict(data_scaled, verbose=0)
mse_per_sample = np.mean((data_scaled - preds) ** 2, axis=1)
mean_err = float(np.mean(mse_per_sample))
std_err = float(np.std(mse_per_sample))
threshold_low = mean_err + 2 * std_err
threshold_high = mean_err + 4 * std_err

print(f"\nReconstruction error: mean={mean_err:.6f}, std={std_err:.6f}")
print(f"Threshold low (mean+2s): {threshold_low:.6f}")
print(f"Threshold high (mean+4s): {threshold_high:.6f}")

# Convert to TFLite
converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite_model = converter.convert()
print(f"TFLite model size: {len(tflite_model)} bytes")

# Output dirs
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# In Docker: /workspace/app/assets/ml  (mounted from ./app/assets/ml)
# On Windows host: <repo>/app/assets/ml
LOCAL_ML = os.path.join(REPO, "app", "assets", "ml")

os.makedirs(LOCAL_ML, exist_ok=True)

# Save files
tflite_path = os.path.join(LOCAL_ML, "vibration_anomaly.tflite")
with open(tflite_path, "wb") as f:
    f.write(tflite_model)

scaler_data = {
    "feature_names": feature_names,
    "mean": scaler.mean_.tolist(),
    "scale": scaler.scale_.tolist(),
}
scaler_path = os.path.join(LOCAL_ML, "vibration_scaler.json")
with open(scaler_path, "w") as f:
    json.dump(scaler_data, f, indent=2)

config_data = {
    "model_version": "5.0",
    "model_type": "autoencoder",
    "input_dim": n_features,
    "thresholds": {
        "low": round(threshold_low, 6),
        "high": round(threshold_high, 6),
    },
    "reconstruction_error_stats": {
        "mean": round(mean_err, 6),
        "std": round(std_err, 6),
    },
}
config_path = os.path.join(LOCAL_ML, "vibration_model_config.json")
with open(config_path, "w") as f:
    json.dump(config_data, f, indent=2)

print(f"\nFiles saved to:\n  {LOCAL_ML}")
print("Done.")
