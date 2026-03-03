#!/usr/bin/env python3
"""
Train Variational Autoencoder (VAE) for archaeological vibration anomaly detection.

Model v4.0 - VAE with 10 input features for v4.0 firmware:
  [rms, ppv, freq, crest, centroid, kurtosis, stalta, arias, cav, temp]

Architecture: 10 -> 8 -> 6 -> (z_mean=4, z_log_var=4) -> 6 -> 8 -> 10
Loss: reconstruction MSE * 10 + KL divergence

Usage:
  python scripts/train_vibration_autoencoder.py --synthetic
  python scripts/train_vibration_autoencoder.py --data path/to/data.csv

Output:
  assets/ml/vibration_anomaly.tflite     (float16 quantized)
  assets/ml/vibration_scaler.json        (StandardScaler, 10 features)
  assets/ml/vibration_model_config.json  (thresholds, metadata)
"""

import argparse
import json
import os
import sys

import numpy as np

os.environ["TF_CPP_MIN_LOG_LEVEL"] = "2"

import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import backend as K
from tensorflow.keras.layers import Dense, Input, Lambda
from tensorflow.keras.models import Model
from sklearn.preprocessing import StandardScaler


# ---------------------------------------------------------------------------
# Feature definitions
# ---------------------------------------------------------------------------

FEATURES_V4 = [
    "rms", "ppv", "freq", "crest", "centroid",
    "kurtosis", "stalta", "arias", "cav", "temp",
]
INPUT_DIM = len(FEATURES_V4)
LATENT_DIM = 4


# ---------------------------------------------------------------------------
# Synthetic data generation
# ---------------------------------------------------------------------------

def generate_synthetic_data(n_total: int = 5000, seed: int = 42) -> np.ndarray:
    """Generate synthetic 'normal' vibration data for training.

    Three regimes mixed together:
      - Ambient / light work  (70%)
      - Footsteps             (20%)
      - Light tools           (10%)
    """
    rng = np.random.RandomState(seed)

    def _uniform(lo, hi, n):
        return rng.uniform(lo, hi, n)

    n_ambient = int(n_total * 0.70)
    n_foot = int(n_total * 0.20)
    n_tools = n_total - n_ambient - n_foot

    # Ambient / light work
    ambient = np.column_stack([
        _uniform(0.001, 0.01, n_ambient),   # rms
        _uniform(0.01, 0.3, n_ambient),      # ppv
        _uniform(0.5, 8, n_ambient),          # freq
        _uniform(1.2, 3.0, n_ambient),        # crest
        _uniform(5, 30, n_ambient),            # centroid
        _uniform(2.5, 3.5, n_ambient),         # kurtosis
        _uniform(0.8, 1.5, n_ambient),         # stalta
        _uniform(0.0001, 0.005, n_ambient),    # arias
        _uniform(0.001, 0.05, n_ambient),      # cav
        _uniform(15, 35, n_ambient),           # temp
    ])

    # Footsteps
    footsteps = np.column_stack([
        _uniform(0.005, 0.02, n_foot),    # rms
        _uniform(0.05, 0.5, n_foot),       # ppv
        _uniform(1, 5, n_foot),             # freq
        _uniform(2.0, 4.0, n_foot),         # crest
        _uniform(3, 15, n_foot),             # centroid
        _uniform(3.0, 5.0, n_foot),          # kurtosis
        _uniform(1.0, 2.5, n_foot),          # stalta
        _uniform(0.001, 0.01, n_foot),       # arias
        _uniform(0.01, 0.1, n_foot),         # cav
        _uniform(15, 35, n_foot),            # temp
    ])

    # Light tools
    tools = np.column_stack([
        _uniform(0.01, 0.05, n_tools),    # rms
        _uniform(0.1, 0.8, n_tools),       # ppv
        _uniform(3, 20, n_tools),           # freq
        _uniform(1.5, 3.5, n_tools),        # crest
        _uniform(10, 40, n_tools),           # centroid
        _uniform(2.8, 4.0, n_tools),         # kurtosis
        _uniform(1.0, 2.0, n_tools),         # stalta
        _uniform(0.005, 0.02, n_tools),      # arias
        _uniform(0.02, 0.15, n_tools),       # cav
        _uniform(15, 35, n_tools),           # temp
    ])

    data = np.vstack([ambient, footsteps, tools])
    rng.shuffle(data)
    return data


# ---------------------------------------------------------------------------
# VAE model builder (Keras 3.x compatible subclassed model)
# ---------------------------------------------------------------------------

class VAE(keras.Model):
    def __init__(self, input_dim=INPUT_DIM, latent_dim=LATENT_DIM, **kwargs):
        super().__init__(**kwargs)
        self.input_dim = input_dim
        self.latent_dim = latent_dim

        # Encoder layers
        self.enc1 = Dense(8, activation="relu", name="enc_dense1")
        self.enc2 = Dense(6, activation="relu", name="enc_dense2")
        self.z_mean_layer = Dense(latent_dim, name="z_mean")
        self.z_log_var_layer = Dense(latent_dim, name="z_log_var")

        # Decoder layers
        self.dec1 = Dense(6, activation="relu", name="dec_dense1")
        self.dec2 = Dense(8, activation="relu", name="dec_dense2")
        self.dec_out = Dense(input_dim, activation="linear", name="dec_output")

        self.total_loss_tracker = keras.metrics.Mean(name="total_loss")
        self.reconstruction_loss_tracker = keras.metrics.Mean(name="reconstruction_loss")
        self.kl_loss_tracker = keras.metrics.Mean(name="kl_loss")

    def encode(self, x):
        h = self.enc1(x)
        h = self.enc2(h)
        z_mean = self.z_mean_layer(h)
        z_log_var = self.z_log_var_layer(h)
        return z_mean, z_log_var

    def reparameterize(self, z_mean, z_log_var):
        batch = tf.shape(z_mean)[0]
        dim = tf.shape(z_mean)[1]
        epsilon = tf.random.normal(shape=(batch, dim))
        return z_mean + tf.exp(0.5 * z_log_var) * epsilon

    def decode(self, z):
        h = self.dec1(z)
        h = self.dec2(h)
        return self.dec_out(h)

    def call(self, x):
        z_mean, z_log_var = self.encode(x)
        z = self.reparameterize(z_mean, z_log_var)
        return self.decode(z)

    def train_step(self, data):
        with tf.GradientTape() as tape:
            z_mean, z_log_var = self.encode(data)
            z = self.reparameterize(z_mean, z_log_var)
            reconstruction = self.decode(z)

            reconstruction_loss = tf.reduce_mean(
                tf.reduce_mean(tf.square(data - reconstruction), axis=-1) * self.input_dim
            )
            kl_loss = tf.reduce_mean(
                -0.5 * tf.reduce_sum(1 + z_log_var - tf.square(z_mean) - tf.exp(z_log_var), axis=-1)
            )
            total_loss = reconstruction_loss + kl_loss

        grads = tape.gradient(total_loss, self.trainable_weights)
        self.optimizer.apply_gradients(zip(grads, self.trainable_weights))

        self.total_loss_tracker.update_state(total_loss)
        self.reconstruction_loss_tracker.update_state(reconstruction_loss)
        self.kl_loss_tracker.update_state(kl_loss)

        return {
            "loss": self.total_loss_tracker.result(),
            "reconstruction_loss": self.reconstruction_loss_tracker.result(),
            "kl_loss": self.kl_loss_tracker.result(),
        }

    @property
    def metrics(self):
        return [
            self.total_loss_tracker,
            self.reconstruction_loss_tracker,
            self.kl_loss_tracker,
        ]

def build_vae(input_dim: int = INPUT_DIM, latent_dim: int = LATENT_DIM):
    """Build a Variational Autoencoder.

    Encoder: input_dim -> 8 -> 6 -> (z_mean, z_log_var) of latent_dim
    Decoder: latent_dim -> 6 -> 8 -> input_dim
    """
    vae = VAE(input_dim=input_dim, latent_dim=latent_dim)
    vae.compile(optimizer=keras.optimizers.Adam(learning_rate=1e-3))

    # Build encoder and decoder as functional models for export
    # Use Lambda layer to wrap reparameterization
    encoder_input = Input(shape=(input_dim,), name="encoder_input")
    h = vae.enc1(encoder_input)
    h = vae.enc2(h)
    z_mean = vae.z_mean_layer(h)
    z_log_var = vae.z_log_var_layer(h)

    # Reparameterization via Lambda
    def sampling(args):
        z_mean_, z_log_var_ = args
        batch = keras.ops.shape(z_mean_)[0]
        dim = keras.ops.shape(z_mean_)[1]
        epsilon = keras.random.normal(shape=(batch, dim))
        return z_mean_ + keras.ops.exp(0.5 * z_log_var_) * epsilon

    z = Lambda(sampling, output_shape=(latent_dim,), name="z")([z_mean, z_log_var])
    encoder = Model(encoder_input, [z_mean, z_log_var, z], name="encoder")

    decoder_input = Input(shape=(latent_dim,), name="decoder_input")
    decoder_h = vae.dec1(decoder_input)
    decoder_h = vae.dec2(decoder_h)
    decoder_output = vae.dec_out(decoder_h)
    decoder = Model(decoder_input, decoder_output, name="decoder")

    return vae, encoder, decoder


# ---------------------------------------------------------------------------
# Anomaly scoring helpers
# ---------------------------------------------------------------------------

def compute_anomaly_scores(
    vae: Model,
    encoder: Model,
    data_scaled: np.ndarray,
    beta: float = 1.0,
) -> np.ndarray:
    """Compute combined anomaly score = reconstruction_mse + beta * kl_div."""
    z_mean, z_log_var, _ = encoder.predict(data_scaled, verbose=0)
    reconstructed = vae.predict(data_scaled, verbose=0)

    # Per-sample reconstruction MSE
    recon_mse = np.mean((data_scaled - reconstructed) ** 2, axis=1)

    # Per-sample KL divergence
    kl_div = -0.5 * np.sum(
        1 + z_log_var - np.square(z_mean) - np.exp(z_log_var), axis=1
    )

    combined = recon_mse + beta * kl_div
    return combined, recon_mse, kl_div


# ---------------------------------------------------------------------------
# Export to TFLite
# ---------------------------------------------------------------------------

def export_tflite(vae: VAE, output_path: str):
    """Export the full VAE (encoder+decoder) to TFLite with float16 quantization."""

    # Build a deterministic inference-only model (no sampling randomness).
    # For inference we use z_mean directly.
    encoder_input = Input(shape=(vae.input_dim,), name="inference_input")
    z_mean, z_log_var = vae.encode(encoder_input)
    # Use z_mean directly (deterministic, no sampling)
    deterministic_output = vae.decode(z_mean)
    inference_model = Model(encoder_input, deterministic_output, name="vae_inference")

    # Convert to TFLite
    converter = tf.lite.TFLiteConverter.from_keras_model(inference_model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float16]
    tflite_model = converter.convert()

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(tflite_model)

    size_kb = len(tflite_model) / 1024
    print(f"  TFLite model saved: {output_path} ({size_kb:.1f} KB)")
    return tflite_model


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Train VAE v4.0 for vibration anomaly detection"
    )
    parser.add_argument(
        "--synthetic", action="store_true",
        help="Generate synthetic training data (5000 samples)"
    )
    parser.add_argument(
        "--data", type=str, default=None,
        help="Path to CSV with real training data"
    )
    parser.add_argument(
        "--epochs", type=int, default=150,
        help="Training epochs (default: 150)"
    )
    parser.add_argument(
        "--batch-size", type=int, default=64,
        help="Batch size (default: 64)"
    )
    parser.add_argument(
        "--beta", type=float, default=1.0,
        help="Weight for KL divergence in anomaly score (default: 1.0)"
    )
    parser.add_argument(
        "--seed", type=int, default=42,
        help="Random seed (default: 42)"
    )
    args = parser.parse_args()

    # Determine project root (script is in scripts/)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    assets_ml = os.path.join(project_root, "assets", "ml")

    print("=" * 60)
    print("  Vibration Anomaly VAE v4.0 Training")
    print("=" * 60)
    print(f"  Features ({INPUT_DIM}): {FEATURES_V4}")
    print(f"  Latent dim: {LATENT_DIM}")
    print(f"  Beta (KL weight): {args.beta}")
    print()

    # --- Load or generate data ---
    if args.synthetic:
        print("[1/5] Generating synthetic training data ...")
        data = generate_synthetic_data(n_total=5000, seed=args.seed)
        print(f"  Generated {data.shape[0]} samples x {data.shape[1]} features")
        is_synthetic = True
    elif args.data:
        print(f"[1/5] Loading data from {args.data} ...")
        import pandas as pd
        df = pd.read_csv(args.data)
        data = df[FEATURES_V4].values
        print(f"  Loaded {data.shape[0]} samples")
        is_synthetic = False
    else:
        print("ERROR: Provide --synthetic or --data <path>")
        sys.exit(1)

    # --- Fit scaler ---
    print("[2/5] Fitting StandardScaler ...")
    scaler = StandardScaler()
    data_scaled = scaler.fit_transform(data)
    print(f"  Mean: {scaler.mean_.round(6).tolist()}")
    print(f"  Scale: {scaler.scale_.round(6).tolist()}")

    # Save scaler
    scaler_path = os.path.join(assets_ml, "vibration_scaler.json")
    os.makedirs(assets_ml, exist_ok=True)
    scaler_json = {
        "mean": scaler.mean_.tolist(),
        "scale": scaler.scale_.tolist(),
        "feature_names": FEATURES_V4,
    }
    with open(scaler_path, "w") as f:
        json.dump(scaler_json, f, indent=2)
    print(f"  Scaler saved: {scaler_path}")

    # --- Build & train VAE ---
    print(f"[3/5] Building & training VAE (epochs={args.epochs}) ...")
    tf.random.set_seed(args.seed)
    np.random.seed(args.seed)

    vae, encoder, decoder = build_vae(INPUT_DIM, LATENT_DIM)
    vae.summary()

    history = vae.fit(
        data_scaled,
        epochs=args.epochs,
        batch_size=args.batch_size,
        shuffle=True,
        verbose=1,
    )
    final_loss = history.history["loss"][-1]
    print(f"  Final loss: {final_loss:.6f}")

    # --- Compute anomaly thresholds ---
    print("[4/5] Computing anomaly thresholds ...")
    combined_scores, recon_scores, kl_scores = compute_anomaly_scores(
        vae, encoder, data_scaled, beta=args.beta
    )

    p50 = float(np.percentile(combined_scores, 50))
    p95 = float(np.percentile(combined_scores, 95))
    p99 = float(np.percentile(combined_scores, 99))
    mean_score = float(np.mean(combined_scores))
    std_score = float(np.std(combined_scores))

    print(f"  Combined score stats:")
    print(f"    Mean: {mean_score:.6f}  Std: {std_score:.6f}")
    print(f"    P50:  {p50:.6f}")
    print(f"    P95:  {p95:.6f}  (threshold_low)")
    print(f"    P99:  {p99:.6f}  (threshold_high)")
    print(f"  Reconstruction MSE  - mean: {np.mean(recon_scores):.6f}")
    print(f"  KL divergence       - mean: {np.mean(kl_scores):.6f}")

    # Save config
    config_path = os.path.join(assets_ml, "vibration_model_config.json")
    config = {
        "model_version": "4.0",
        "model_type": "vae",
        "input_features": FEATURES_V4,
        "input_dim": INPUT_DIM,
        "latent_dim": LATENT_DIM,
        "beta": args.beta,
        "thresholds": {
            "threshold_low": p95,
            "threshold_high": p99,
            "mean_error": mean_score,
            "std_error": std_score,
        },
        "training_samples": int(data.shape[0]),
        "training_epochs": args.epochs,
        "final_loss": float(final_loss),
        "synthetic_data": is_synthetic,
        "description": "VAE for archaeological site vibration anomaly detection",
        "standard": "DIN 4150-3",
    }
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print(f"  Config saved: {config_path}")

    # --- Export TFLite ---
    print("[5/5] Exporting TFLite (float16) ...")
    tflite_path = os.path.join(assets_ml, "vibration_anomaly.tflite")
    export_tflite(vae, tflite_path)

    print()
    print("=" * 60)
    print("  Training complete!")
    print(f"  Model: {tflite_path}")
    print(f"  Config: {config_path}")
    print(f"  Scaler: {scaler_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()
