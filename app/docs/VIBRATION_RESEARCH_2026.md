# Comprehensive Vibration Analysis & SHM Research Report
## AncientVision Project - State of the Art (2025-2026)

> This document compiles cutting-edge research across 12 domains for building the most scientifically rigorous vibration monitoring system for archaeological site protection.

---

## Table of Contents
1. [Advanced Signal Processing](#1-advanced-signal-processing-for-vibration)
2. [Seismology Algorithms](#2-seismology-algorithms-state-of-the-art)
3. [Structural Health Monitoring](#3-structural-health-monitoring-shm-2024-2026)
4. [Machine Learning for Vibration](#4-machine-learning-for-vibration-analysis-2024-2026)
5. [International Standards](#5-international-standards-deep-dive)
6. [Archaeological/Heritage Research](#6-archaeologicalheritage-vibration-research)
7. [Advanced PPV and Velocity Analysis](#7-advanced-ppv-and-velocity-analysis)
8. [ESP32/MEMS Optimization](#8-esp32mems-accelerometer-optimization)
9. [Real-Time Alert Systems](#9-real-time-alert-systems)
10. [Data Management & Visualization](#10-data-management-and-visualization)
11. [Emerging Technologies](#11-emerging-technologies-2025-2026)
12. [Vibration Source Characterization](#12-vibration-source-characterization)

---

## 1. Advanced Signal Processing for Vibration

### 1.1 Wavelet Transform (CWT/DWT) vs FFT

**Technique**: Continuous Wavelet Transform (CWT) and Discrete Wavelet Transform (DWT) decompose signals into time-frequency representations using scaled and translated mother wavelets.

**Key Advantage Over FFT**: Wavelets provide multi-resolution analysis -- high frequency resolution at low frequencies, and high time resolution at high frequencies. FFT only provides frequency information with no time localization. For non-stationary signals (transient impacts, seismic events), wavelets are vastly superior.

**Mathematical Formulation**:
```
CWT: W(a,b) = (1/sqrt(a)) * integral[ x(t) * psi*((t-b)/a) dt ]
DWT: W(j,k) = sum[ x(n) * psi(j,k)(n) ]   where psi(j,k)(n) = 2^(j/2) * psi(2^j * n - k)
```
Where `a` = scale, `b` = translation, `psi` = mother wavelet (Morlet, Daubechies, Haar, etc.)

**Implementability**:
- **ESP32**: YES -- DWT is computationally efficient (O(N) vs FFT's O(N log N)). The `wavelib` C library (github.com/rafat/wavelib) has been used on Arduino/ESP32 for real-time DWT. A dedicated ESP32 repo exists: github.com/esther9603/Real-Time-DWT
- **Mobile (Flutter/Dart)**: YES -- Can use dart FFI to call C wavelet libraries, or implement Haar DWT natively (simple lifting scheme)

**Open-Source Implementations**:
- `wavelib` (C): github.com/rafat/wavelib -- DWT, SWT, MODWT, CWT, WPT
- `fCWT` (C++): github.com/fastlib/fCWT -- Fast CWT, highly optimized
- `PyWavelets` (Python): pywavelets.readthedocs.io -- Reference implementation
- `ircam-ismm/wavelet` (C++): github.com/ircam-ismm/wavelet -- Online CWT estimation with minimal delay

**Archaeological Relevance**: HIGH -- Transient events (construction impacts, seismic P-waves, machinery start/stop) are inherently non-stationary. DWT on ESP32 can detect and classify these events with time-frequency precision that FFT cannot provide.

**Recommended for AncientVision**: Implement 3-level Haar DWT on ESP32 for transient detection alongside existing FFT. Use Daubechies-4 (db4) on mobile for detailed time-frequency analysis of recorded events.

---

### 1.2 Hilbert-Huang Transform (HHT) / Empirical Mode Decomposition (EMD)

**Technique**: HHT is a two-step process: (1) Empirical Mode Decomposition (EMD) decomposes a signal into Intrinsic Mode Functions (IMFs), then (2) Hilbert Transform is applied to each IMF to obtain instantaneous frequency and amplitude.

**Key Paper**: Huang, N.E. et al. (1998). "The empirical mode decomposition and the Hilbert spectrum for nonlinear and non-stationary time series analysis." *Proceedings of the Royal Society of London A*, 454, 903-995.

**Mathematical Formulation**:
```
EMD: x(t) = sum(i=1..N)[ IMF_i(t) ] + r_N(t)     (residual)
Hilbert Transform: H[x(t)] = (1/pi) * PV integral[ x(tau)/(t-tau) dtau ]
Instantaneous Frequency: omega(t) = d(phase(t))/dt
```

**Key Advantages**:
- Fully adaptive -- no pre-defined basis functions (unlike wavelets)
- Handles nonlinear AND non-stationary signals
- Preserves time-domain characteristics -- IMFs have same length as original signal
- Can detect damage time instants and structural stiffness changes

**Limitations & Solutions**:
- Mode mixing problem -- solved by Ensemble EMD (EEMD, Wu & Huang 2009)
- End effects -- use mirror extension or masking signals
- Computationally intensive -- not suitable for real-time ESP32

**Recent 2025-2026 Advances**:
- Hybrid SHM using interstory drift angle + HHT-based nonlinearity detection (Saddek, 2026, Wiley)
- Combined EMD + AM/FM demodulation for structural damage identification

**Implementability**:
- **ESP32**: NO (too computationally expensive for real-time, requires iterative sifting)
- **Mobile**: YES -- can process recorded segments. Python reference: `PyEMD` library

**Open-Source**: `PyEMD` (Python), `libeemd` (C library for EEMD)

**Archaeological Relevance**: HIGH -- Can separate overlapping vibration sources (traffic + wind + seismic) that plague archaeological sites. Each source appears as a separate IMF.

---

### 1.3 Short-Time Fourier Transform (STFT)

**Technique**: Windowed FFT that slides across the signal, providing time-frequency representation.

**Mathematical Formulation**:
```
STFT(t,f) = integral[ x(tau) * w(tau - t) * exp(-j*2*pi*f*tau) dtau ]
```
Where `w` = window function (Hanning, Hamming, Blackman, etc.)

**Key Limitation**: Fixed time-frequency resolution trade-off (Heisenberg uncertainty). Wide window = good frequency resolution, poor time resolution, and vice versa.

**Implementability**:
- **ESP32**: YES -- Sliding window FFT is straightforward with existing arduinoFFT
- **Mobile**: YES -- trivial to implement

**Archaeological Relevance**: MEDIUM -- Good for spectrogram visualization but limited by fixed resolution. Better alternatives exist (CWT, SST).

---

### 1.4 Synchrosqueezed Transform (SST)

**Technique**: Post-processing step applied to CWT or STFT that "squeezes" the time-frequency representation to achieve sharper frequency resolution by reassigning energy to instantaneous frequency estimates.

**Key Paper**: Daubechies, I., Lu, J., & Wu, H.-T. (2011). "Synchrosqueezed wavelet transforms: An empirical mode decomposition-like tool." *Applied and Computational Harmonic Analysis*, 30(2), 243-261.

**Three-Step Process**:
1. Compute CWT for varying time-frequency resolution
2. Calculate instantaneous frequencies for enhanced readability
3. Frequency reassignment to counter spectral smearing

**Key Advantage**: Combines CWT's multi-resolution capability with EMD's adaptivity, but with a solid mathematical foundation. Much improved readability in frequency direction compared to CWT alone.

**2024-2025 Advances**:
- Synchroextracting transform for earthquake-induced structural damage identification
- Optimization of synchrosqueezed fractional wavelet transform for bearing diagnosis
- SST + Fast Kurtogram for combined fault detection

**Implementability**:
- **ESP32**: NO (requires full CWT + post-processing)
- **Mobile**: YES -- `ssqueezepy` Python library (github.com/OverLordGoldDragon/ssqueezepy)

**Open-Source**: `ssqueezepy` (Python), MATLAB Wavelet Toolbox (wsst function)

**Archaeological Relevance**: HIGH -- Superior to all other time-frequency methods for identifying time-varying structural resonance shifts that indicate damage onset.

---

### 1.5 Wigner-Ville Distribution (WVD)

**Technique**: Quadratic time-frequency representation with theoretically optimal time-frequency resolution.

**Mathematical Formulation**:
```
WVD(t,f) = integral[ x(t + tau/2) * x*(t - tau/2) * exp(-j*2*pi*f*tau) dtau ]
```

**Advantage**: Best possible joint time-frequency resolution (no Heisenberg trade-off for mono-component signals).

**Critical Limitation**: Cross-terms appear between every pair of signal components, making it nearly useless for multi-component signals without smoothing (Pseudo-WVD, Smoothed Pseudo-WVD), which sacrifices resolution.

**Implementability**: Mobile only. Not recommended for AncientVision due to cross-term issues.

---

### 1.6 Variational Mode Decomposition (VMD)

**Technique**: Decomposes a signal into a discrete number of sub-signals (modes) with specific sparsity properties. Unlike EMD, VMD is mathematically well-founded (variational optimization).

**Key Paper**: Dragomiretskiy, K. & Zosso, D. (2014). "Variational Mode Decomposition." *IEEE Transactions on Signal Processing*, 62(3), 531-544.

**Mathematical Formulation**:
```
Minimize: sum_k[ ||partial_t[ delta(t) + j/(pi*t) ] * u_k(t) * exp(-j*omega_k*t) ||^2 ]
Subject to: sum_k[ u_k ] = f      (signal reconstruction)
```

**2024-2026 Advances**:
- **VFW-VMD** (Variable Filtered-Waveform VMD): Fractional-order constraints with dynamically adjusting filter waveforms to mitigate mode mixing and over-smoothing
- **Hybrid EMD-VMD**: Combines EMD's adaptivity with VMD's spectral precision
- **Automatic parameter setting VMD**: Eliminates manual selection of mode number K and penalty alpha
- **VMD + ARIMA** for structural damage identification (2025)

**Implementability**:
- **ESP32**: PARTIAL -- Simplified VMD possible for 2-3 modes
- **Mobile**: YES -- Full implementation feasible

**Open-Source**: `vmdpy` (Python), MATLAB VMD toolbox

**Archaeological Relevance**: HIGH -- Excellent for separating narrowband vibration sources (machinery harmonics) from broadband seismic/impact events at excavation sites.

---

### 1.7 Wavelet Packet Decomposition (WPD)

**Technique**: Extension of DWT that decomposes both approximation AND detail coefficients at each level, providing a complete binary tree of frequency sub-bands.

**Advantage Over DWT**: Uniform frequency bandwidth at all scales, allowing analysis of high-frequency content with the same resolution as low-frequency.

**Implementability**: ESP32 (using wavelib library), Mobile (yes)

**Archaeological Relevance**: MEDIUM -- Useful for detecting specific frequency bands associated with particular damage mechanisms.

---

### 1.8 Adaptive Filtering (Kalman, LMS, RLS)

#### Kalman Filter
**Formulation**:
```
Predict: x_hat(k|k-1) = F*x_hat(k-1|k-1)
         P(k|k-1) = F*P(k-1|k-1)*F' + Q
Update:  K(k) = P(k|k-1)*H' * [H*P(k|k-1)*H' + R]^(-1)
         x_hat(k|k) = x_hat(k|k-1) + K(k)*[z(k) - H*x_hat(k|k-1)]
         P(k|k) = [I - K(k)*H]*P(k|k-1)
```
- Converges ~8x faster than RLS for vibration cancellation
- Successfully demonstrated on microcontrollers with accelerometers

#### LMS (Least Mean Squares)
```
w(n+1) = w(n) + 2*mu*e(n)*x(n)
```
- Simplest adaptive filter, low computation (O(N) per sample)
- Best for ESP32 real-time noise cancellation

#### RLS (Recursive Least Squares)
```
P(n) = (1/lambda) * [P(n-1) - P(n-1)*x(n)*x'(n)*P(n-1) / (lambda + x'(n)*P(n-1)*x(n))]
w(n) = w(n-1) + P(n)*x(n)*e(n)
```
- Fastest convergence, lowest MSE, but O(N^2) computation
- Too expensive for ESP32 with large filter orders

**Implementability**:
- **ESP32**: LMS (yes, trivially), Kalman (yes, small state), RLS (limited)
- **Mobile**: All three (yes)

**Archaeological Relevance**: HIGH -- Real-time noise cancellation is critical. LMS on ESP32 can adaptively cancel known interference (power-line harmonics at 50/60Hz, machinery RPM harmonics).

**Recommendation for AncientVision**: Implement NLMS (Normalized LMS) on ESP32 for adaptive notch filtering of known interference frequencies.

---

### 1.9 Higher-Order Spectral Analysis (Bispectrum, Trispectrum)

**Technique**: Extension of power spectrum to higher statistical orders. Bispectrum (3rd order) detects phase coupling between frequency components; trispectrum (4th order) detects higher-order nonlinear interactions.

**Mathematical Formulation**:
```
Bispectrum: B(f1, f2) = E[X(f1) * X(f2) * X*(f1+f2)]
Trispectrum: T(f1,f2,f3) = E[X(f1)*X(f2)*X(f3)*X*(f1+f2+f3)]
```

**Key Properties**:
- Suppress Gaussian noise (which has zero bispectrum)
- Detect nonlinear coupling -- crucial for identifying damage-induced nonlinearity
- Preserve phase information lost in power spectrum

**Implementability**:
- **ESP32**: NO (computationally prohibitive)
- **Mobile**: YES for small FFT sizes

**Archaeological Relevance**: MEDIUM -- Can detect nonlinear behavior in damaged structures (crack breathing, loose connections), but computationally demanding.

---

### 1.10 Spectral Kurtosis

**Technique**: Frequency-domain kurtosis that identifies frequency bands containing impulsive/transient content.

**Key Paper**: Antoni, J. (2006). "The spectral kurtosis: a useful tool for characterising non-stationary signals." *Mechanical Systems and Signal Processing*, 20(2), 282-307.

**Mathematical Formulation**:
```
SK(f) = <|X(t,f)|^4> / <|X(t,f)|^2>^2 - 2
```
Where < > denotes time averaging of STFT coefficients.

**Kurtogram**: 2D map of spectral kurtosis vs. center frequency and bandwidth, automatically identifying the optimal demodulation band. Combined with envelope analysis (Hilbert transform), achieves 95%+ fault detection accuracy.

**Implementability**:
- **ESP32**: PARTIAL (simplified version with fixed bands)
- **Mobile**: YES

**Archaeological Relevance**: HIGH -- Automatically identifies frequency bands where transient impacts occur, filtering out steady-state background vibration.

---

### 1.11 Envelope Analysis (Demodulation)

**Technique**: Extract the amplitude modulation envelope of a bandpass-filtered signal using Hilbert Transform.

**Process**:
1. Bandpass filter around frequency of interest (identified by spectral kurtosis or kurtogram)
2. Apply Hilbert Transform to get analytic signal
3. Compute envelope = |analytic signal|
4. FFT of envelope reveals modulation frequencies

**Implementability**: ESP32 (yes, Hilbert via FFT), Mobile (yes)

**Archaeological Relevance**: MEDIUM -- More relevant for machinery monitoring than seismic events.

---

### 1.12 Zero-Crossing Rate (ZCR)

**Technique**: Count the number of times the signal crosses zero per unit time. Proportional to dominant frequency for narrowband signals.

**Formula**: `ZCR = (1/2N) * sum(|sign(x[n]) - sign(x[n-1])|)`

**Implementability**: ESP32 (trivial, O(N)), Mobile (trivial)

**Archaeological Relevance**: LOW -- Simple frequency estimator, but our FFT provides much more information.

---

### 1.13 Autocorrelation and Cross-Correlation

**Technique**: Measure similarity of a signal with a time-shifted version of itself (auto) or another signal (cross).

**Formula**:
```
R_xx(tau) = E[x(t) * x(t+tau)]
R_xy(tau) = E[x(t) * y(t+tau)]
```

**Key Uses**:
- Autocorrelation: Period estimation, noise floor characterization
- Cross-correlation: Time-delay estimation between sensors (source localization)

**Implementability**: ESP32 (yes via FFT), Mobile (yes)

**Archaeological Relevance**: HIGH for multi-sensor arrays -- cross-correlation enables vibration source localization.

---

## 2. Seismology Algorithms (State of the Art)

### 2.1 STA/LTA Variants

#### Classic STA/LTA (Currently Implemented)
```
R(i) = STA(i) / LTA(i)
STA(i) = (1/ns) * sum(j=i-ns..i)[ |x(j)|^2 ]
LTA(i) = (1/nl) * sum(j=i-nl..i)[ |x(j)|^2 ]
```
Best overall performance: 98.2% precision (only 1 missed event out of 58 in comparative studies).

#### Recursive STA/LTA
```
STA(i) = (1-1/ns)*STA(i-1) + (1/ns)*|x(i)|^2
LTA(i) = (1-1/nl)*LTA(i-1) + (1/nl)*|x(i)|^2
```
- More memory efficient (no array storage needed)
- Suitable for real-time continuous monitoring
- Used in ObsPy for network coincidence triggering

#### Delayed STA/LTA
- Introduces a gap between STA and LTA windows
- Prevents contamination of LTA by the onset of the event
- Better for weak events with gradual onset

#### Carl-STA/LTA
- Uses STA-LTA difference instead of ratio
- Better at detecting the highest event peak of S-waves
- Useful for distinguishing seismic vs non-seismic activity

**Key Reference**: Withers et al. (1998). "A comparison of select trigger algorithms for automated global seismic phase and event detection." *Bulletin of the Seismological Society of America*, 88(1), 95-106.

**Implementability**: ALL on ESP32 (recursive is most memory-efficient)

**Recommendation for AncientVision**: Switch from classic to **Recursive STA/LTA** on ESP32 to save memory. Add Delayed STA/LTA on mobile for post-processing weak events.

---

### 2.2 P-wave and S-wave Arrival Time Picking

#### AR-AIC (Autoregressive Akaike Information Criterion)
```
AIC(k) = k*log(var(x[1..k])) + (N-k-1)*log(var(x[k+1..N]))
P-arrival = argmin(AIC)
```
Available in ObsPy as `ar_pick()`. Picks both P and S arrivals.

#### Baer-Kradolfer Picker
- Uses STA/LTA + envelope function + characteristic function
- Designed for automatic processing of seismic networks

**Key Paper**: Baer, M. & Kradolfer, U. (1987). "An automatic phase picker for local and teleseismic events." *Bulletin of the Seismological Society of America*, 77(4), 1437-1445.

**Implementability**: ESP32 (AR-AIC feasible for small windows), Mobile (both)

---

### 2.3 Deep Learning Phase Picking

#### PhaseNet
**Architecture**: U-Net-style deep neural network
**Input**: 3-component seismic waveforms (30-second windows)
**Output**: Probability distributions for P-arrival, S-arrival, and noise
**Key Paper**: Zhu, W. & Beroza, G.C. (2019). "PhaseNet: a deep-neural-network-based seismic arrival-time picking method." *Geophysical Journal International*, 216(1), 261-273.
**GitHub**: github.com/AI4EPS/PhaseNet

#### EQTransformer
**Architecture**: Encoder (like PhaseNet downsampling) + residual convolutions + LSTM + Transformer attention blocks
**Capability**: Simultaneous earthquake detection AND phase picking
**Key Paper**: Mousavi, S.M. et al. (2020). "Earthquake transformer -- an attentive deep-learning model for simultaneous earthquake detection and phase picking." *Nature Communications*, 11, 3952.

#### PLAN (2023-2024)
Superior to PhaseNet and EQTransformer for S-wave picking specifically.

#### PhaseNO (2025 -- Fourier Neural Operator)
Uses multi-station contextual inference via Fourier Neural Operator (FNO) and Graph Neural Operators (GNO), departing from single-station paradigms.

**Implementability**:
- **ESP32**: NO (models are too large: 100K-1M+ parameters)
- **Mobile (TFLite)**: POSSIBLE with quantization for PhaseNet (smallest model)

**Archaeological Relevance**: HIGH -- Accurate phase picking enables P-wave early warning (seconds before damaging S-wave arrives).

---

### 2.4 HVSR (Horizontal-to-Vertical Spectral Ratio)

**Technique**: Ratio of horizontal to vertical Fourier amplitude spectra of ambient noise, used to estimate site fundamental frequency and amplification.

**Formula**:
```
HVSR(f) = sqrt(S_NS(f)^2 + S_EW(f)^2) / S_Z(f)
```

**Key Application**: Seismic microzonation -- maps spatial variations in sediment thickness and identifies amplification zones at archaeological sites.

**SESAME Guidelines**: Standardized methodology for MHVSR measurements.

**Important Caveat**: MEMS accelerometers with broad full scale may produce unreliable HVSR results. High-sensitivity instruments (< 1 ng/sqrt(Hz) noise floor) are needed.

**Implementability**: Mobile (yes, from recorded tri-axial data), ESP32 (compute ratio from existing FFT)

**Archaeological Relevance**: CRITICAL -- Determines site-specific amplification that could increase vibration damage risk at archaeological sites built on soft sediments.

---

### 2.5 Magnitude Estimation from MEMS

MEMS accelerometers can estimate earthquake magnitude using:
- PGA (Peak Ground Acceleration) correlation
- CAV (Cumulative Absolute Velocity)
- Significant duration

**MyShake App**: 200,000+ users providing crowd-sourced seismic data from phone MEMS sensors, demonstrating viability of consumer MEMS for earthquake detection.

**Implementability**: ESP32 and Mobile (PGA is just peak acceleration value)

---

### 2.6 Additional Seismology Algorithms

#### ETAS Model (Epidemic-Type Aftershock Sequence)
Statistical model for earthquake clustering. Not implementable on device but useful for risk assessment context.

#### Gutenberg-Richter Law
```
log10(N) = a - b*M
```
Where N = number of earthquakes >= magnitude M. b-value analysis indicates seismic hazard level.

#### Seismic Interferometry
Cross-correlation of ambient noise between sensor pairs to extract Green's functions. Requires multiple sensors.

---

## 3. Structural Health Monitoring (SHM) 2024-2026

### 3.1 Operational Modal Analysis (OMA)

**Technique**: Extract modal parameters (natural frequencies, damping ratios, mode shapes) using only ambient vibration response -- no forced excitation needed.

#### Frequency Domain Decomposition (FDD)
1. Compute cross-spectral density matrix from multi-channel measurements
2. Apply SVD at each frequency line
3. Peaks in first singular value = natural frequencies
4. First singular vector at peak = mode shape estimate

**Key Paper**: Brincker, R., Zhang, L., & Andersen, P. (2001). "Modal identification of output-only systems using frequency domain decomposition." *Smart Materials and Structures*, 10(3), 441.

#### Stochastic Subspace Identification (SSI)
Models structure as state-space system:
```
x(k+1) = A*x(k) + w(k)
y(k) = C*x(k) + v(k)
```
Uses block Hankel matrices and SVD to extract system matrices A, C, then eigenvalues give frequencies/damping and eigenvectors give mode shapes.

**2025 Advances**:
- ML-based automated SSI with hyperparameter optimization
- Automated OMA using stabilization diagrams with machine learning clustering

**Implementability**:
- **ESP32**: NO (requires large matrix operations)
- **Mobile**: POSSIBLE for simplified FDD with 2-3 channels

**Archaeological Relevance**: CRITICAL -- Natural frequency tracking is the gold standard for damage detection in heritage structures. A 1-2% shift in fundamental frequency indicates structural damage onset.

---

### 3.2 Natural Frequency Tracking for Damage Detection

**Principle**: Structural damage reduces stiffness, which lowers natural frequencies. Continuous monitoring of resonant frequencies provides the earliest indicator of damage.

**Temperature Compensation**: Essential for long-term monitoring. Natural frequencies vary 0.1-0.5% per degree C due to material stiffness changes. Must apply temperature regression to separate damage effects from environmental effects.

**Implementation Strategy**:
1. ESP32: Compute FFT, find spectral peaks, transmit peak frequencies
2. Mobile: Track peak frequencies over time, apply temperature regression
3. Alert when temperature-compensated frequency deviates > 2 standard deviations from baseline

---

### 3.3 Damage-Sensitive Features

#### Modal Assurance Criterion (MAC)
```
MAC(phi_A, phi_B) = |phi_A' * phi_B|^2 / (phi_A'*phi_A * phi_B'*phi_B)
```
Compares mode shapes before/after damage. MAC = 1.0 = identical, < 0.9 indicates potential damage.

#### Coordinate Modal Assurance Criterion (COMAC)
Localizes damage by computing MAC per sensor location.

#### Flexibility-Based Methods
Change in flexibility matrix F = Phi * Lambda^(-1) * Phi' is more sensitive to damage than mode shapes alone.

---

### 3.4 Statistical Pattern Recognition for SHM

**Key Reference**: Worden, K. & Farrar, C.R. (2007). "An introduction to structural health monitoring." *Philosophical Transactions of the Royal Society A*, 365(1851), 303-315.

Four-level SHM paradigm:
1. **Detection**: Is damage present?
2. **Localization**: Where is the damage?
3. **Classification**: What type of damage?
4. **Quantification**: How severe is the damage?

Mahalanobis distance for novelty detection:
```
D = sqrt((x - mu)' * Sigma^(-1) * (x - mu))
```

**Implementability**: Mobile (yes, small feature vectors)

---

### 3.5 Physics-Informed Neural Networks (PINNs)

**Technique**: Neural networks that embed physical laws (PDEs of structural dynamics) as loss function constraints, requiring much less training data than standard NNs.

**2025 Advances**:
- **A-PINN**: Auxiliary PINNs for continuous Euler-Bernoulli beam vibration analysis
- **Two-Scale PINNs (TSPINNs)**: Improved prediction accuracy for structural dynamics parameter inversion, validated on T-shaped tower monitoring
- **RK4-PINN + DDPG**: Reduced displacement control time to half of GA-PID

**Key Advantage**: Requires substantially smaller training data than traditional ANNs and generalizes better.

**Implementability**:
- **ESP32**: NO
- **Mobile (TFLite)**: POSSIBLE for inference of pre-trained small PINNs

**Archaeological Relevance**: HIGH -- Can model complex heritage structures with limited sensor data by incorporating known physics of masonry behavior.

---

### 3.6 Digital Twins for Heritage Structures

**2025 State of the Art**:
- Automatic damage information updating within DT models using Extremely Many-Objective Evolutionary Algorithms (EMaOEA)
- Finite Element Model Updating (FEMU) using Genetic Algorithms and Bayesian inference
- Hierarchical Bayesian Modeling (HBM) for uncertainty estimation
- Sequential Monte Carlo (SMC) for parameter updating from heterogeneous sensor data
- TWIN-ADAPT framework for continuous learning against concept drift

**Key Paper**: Recent digital twin technique for automatic damage detection of historical buildings with adaptive model updating (2025, Mechanical Systems and Signal Processing).

**Archaeological Relevance**: Future direction -- not directly implementable on current AncientVision hardware but represents the ultimate goal of comprehensive site monitoring.

---

### 3.7 Long-Term Monitoring Strategies

**Key Considerations**:
- Seasonal temperature effects on natural frequencies (0.1-0.5%/deg C)
- Moisture effects on masonry stiffness (can cause 5-10% frequency variation)
- Sensor drift and calibration checks
- Statistical process control (control charts) for anomaly detection
- Bayesian recursive updating of baseline parameters

---

## 4. Machine Learning for Vibration Analysis (2024-2026)

### 4.1 1D CNN for Vibration Classification

**Architecture**: 1D convolutional layers applied directly to raw vibration time series.

**Typical Architecture**:
```
Input(256 samples) -> Conv1D(32, kernel=7) -> BN -> ReLU -> MaxPool
-> Conv1D(64, kernel=5) -> BN -> ReLU -> MaxPool
-> Conv1D(128, kernel=3) -> BN -> ReLU -> GlobalAvgPool
-> Dense(num_classes) -> Softmax
```

**Performance**: Achieves 92%+ fault detection accuracy on ESP32 (TinyML deployment).

**2025 Results**: ESP32-based TinyML 1D-CNN achieves >92% fault detection with compact computational footprint.

**Implementability**:
- **ESP32**: YES with INT8 quantization (TensorFlow Lite Micro)
- **Mobile**: YES (TFLite)

**Recommendation for AncientVision**: Replace or augment current autoencoder with 1D CNN classifier for vibration event categorization (seismic/machinery/impact/ambient).

---

### 4.2 LSTM/GRU for Time-Series Prediction

**Architecture**: Recurrent neural networks with memory gates for sequential data.

**Application**: Predict future vibration levels from past observations. Alert if predicted trend indicates increasing severity.

**Implementability**:
- **ESP32**: LIMITED (LSTM is memory-intensive due to gate matrices)
- **Mobile**: YES

---

### 4.3 Transformer Models for Vibration

**2025 Key Developments**:
- **MTFC-T** (Multiscale Time-Frequency CNN-Transformer): Handles noise interference AND temporal dependencies
- **ECMCTP** (Efficient Cross Space Multiscale CNN Transformer Parallelism): Transforms 1D vibration to 2D time-frequency images via CWT, then applies CNN-Transformer
- **T-VAE** (Transformer-based VAE): Self-attention + residual networks for multivariate time series anomaly detection

**Implementability**:
- **ESP32**: NO (attention mechanisms are memory-prohibitive)
- **Mobile**: POSSIBLE with distilled/quantized models

---

### 4.4 Variational Autoencoders (VAE) vs Standard Autoencoders

**Current AncientVision**: Standard autoencoder (7->6->4->3->4->6->7)

**VAE Advantage**: Learns a structured latent space with probabilistic distribution, enabling:
- Better anomaly scoring via reconstruction probability (not just MSE)
- Generation of synthetic training data
- Smoother latent space for interpolation

**VAE Loss**:
```
L = E[log p(x|z)] - KL(q(z|x) || p(z))
    = Reconstruction Loss + KL Divergence
```

**2025 Advances**:
- GCN-VAE: Graph Convolutional Network + VAE for multi-sensor vibration anomaly detection
- MST-VAE: Multi-Scale Temporal VAE for multivariate time series
- Planar Flow VAE: Normalizing flows in latent space for better posterior approximation

**Recommendation for AncientVision**: Upgrade from standard autoencoder to VAE with the same architecture. The KL divergence regularization will improve anomaly detection sensitivity and reduce false positives.

---

### 4.5 Normalizing Flows for Anomaly Detection

**Technique**: Learn complex probability distributions through a sequence of invertible transformations. Anomaly score = negative log-likelihood under learned distribution.

**Advantage over VAE**: Exact likelihood computation (no ELBO approximation).

**Implementability**: Mobile only (too complex for ESP32).

---

### 4.6 Graph Neural Networks (GNN) for SHM

**2025 Key Results**:
- **LGSTA-GNN**: Local-Global Spatiotemporal Attention GNN for bridge damage detection -- outperforms all conventional deep learning methods
- **TPF-GNet**: Temporal Power Flow Graph Network -- physics-informed, unsupervised damage detection via energy transmission patterns
- **Aerospace GNN**: AUC 0.97 for damage detection, ~3% localization error

**Key Concept**: Model sensor network as a graph where nodes = sensors, edges = spatial/structural relationships.

**Implementability**: Mobile only (requires multi-sensor data).

**Archaeological Relevance**: HIGH for multi-sensor deployments at large archaeological sites.

---

### 4.7 Self-Supervised / Contrastive Learning

**SimCLR-TS**: Adaptation of SimCLR to time-series industrial data.

**Data Augmentation Techniques for Vibration**:
- Bidirectional flipping
- Random cropping and resizing
- Noise injection
- Blockout (random zeroing of segments)
- Time warping
- Channel permutation (for multi-axis)

**Key Advantage**: Learn robust features from UNLABELED vibration data -- critical for archaeological sites where labeled damage data is extremely scarce.

**Implementability**: Training offline (Python/PyTorch), inference on mobile (TFLite)

---

### 4.8 TinyML Advances (2025-2026)

**Key Benchmarks**:
- 1D CNN on ESP32: >92% fault detection accuracy
- ESP32-S3 with transfer learning: 88.28% accuracy, 45ms inference, 17.7mJ energy
- Average inference time for anomaly detection: 25ms
- Typical model size: 5-50 KB (INT8 quantized)

**2026 Industry Trends**:
- INT8 quantization as default precision standard
- ONNX as interoperability format
- Arm Ethos-U NPUs in mid-range MCUs
- Combined knowledge distillation + quantization pipelines
- Quantization-aware training (QAT) superior to post-training quantization (PTQ)

**ESP32-S3 Specific**:
- SIMD vector instructions (512-bit vectors)
- ESP-DL library for optimized NN inference
- ESP-NN and ESP-DSP for SIMD acceleration
- 16-bit model: 6.25x speedup with SIMD
- 8-bit model: 2.5x speedup with SIMD

**INT4 Status**: While promising in simulation, current toolchains only support INT8 in practice.

**Recommendation for AncientVision**: If upgrading to ESP32-S3, can significantly improve ML inference performance. Current autoencoder (~5KB) is well within bounds.

---

### 4.9 Foundation Models for Time Series

#### Chronos-2 (Amazon, October 2025)
- 120M parameters, encoder-only architecture
- Zero-shot forecasting for univariate, multivariate, and covariate-informed tasks
- GitHub: github.com/amazon-science/chronos-forecasting

#### MOMENT (ICML 2024)
- Encoder-only with masked modeling objectives
- Open source: github.com/moment-timeseries-foundation-model/moment

#### TimeGPT (Nixtla)
- Trained on 100B+ data points across domains including IoT sensor data

**Archaeological Application**: Zero-shot vibration forecasting could predict vibration trends without task-specific training. However, these models are too large for edge deployment (100M+ parameters).

---

### 4.10 Online / Continual Learning for Adaptive Baselines

**Key Challenge**: Concept drift -- sensor data distributions change over time due to seasonal effects, sensor aging, site changes.

**2025 Frameworks**:
- **TWIN-ADAPT**: Continuous learning within digital twin framework for dynamic anomaly classification
- **METER**: Dynamic concept adaptation with base model + drift detection + online adaptation
- **AnDri**: Adaptive time-series anomaly detection cognizant of concept drift
- **SCS/MACS**: Segmented Confidence Sequences and Multi-Scale Adaptive Confidence Segments for adaptive thresholding

**Implementability**:
- **ESP32**: PARTIAL (simple exponential moving average baseline update)
- **Mobile**: YES (can implement lightweight online learning)

**Recommendation for AncientVision**: Implement adaptive baseline update on mobile using exponential weighted moving average with seasonal decomposition. Alert thresholds should auto-adjust based on time-of-day and day-of-week patterns.

---

### 4.11 Federated Learning for Distributed Sensors

**Concept**: Multiple sensor nodes collaboratively train a shared model without sharing raw data.

**2025 Key Development**: Ensemble Federated Learning (EFL) with cloud integration for WSN anomaly detection -- enhances accuracy while preserving data privacy.

**Archaeological Relevance**: MEDIUM-HIGH for large sites with multiple monitoring nodes. Each node trains locally, shares only model updates.

---

## 5. International Standards Deep Dive

### 5.1 Comprehensive PPV Limits Comparison Matrix

| Standard | Scope | Heritage/Sensitive PPV Limits | Residential PPV Limits | Commercial/Industrial PPV Limits |
|----------|-------|-------------------------------|------------------------|----------------------------------|
| **DIN 4150-3:2016** | Germany | 3 mm/s (1-10Hz), 3-8 mm/s (10-50Hz), 8-10 mm/s (50-100Hz) | 5-20 mm/s (freq dependent) | 20-50 mm/s (freq dependent) |
| **BS 7385-2:1993** | UK | No specific heritage category | 15-50 mm/s (Type 1: reinforced) | 15-50 mm/s |
| **SN 640312a** | Switzerland | Machine class I (sensitive): 1.5-5 mm/s | Class II: 3-10 mm/s | Class III-IV: 6-40 mm/s |
| **AS 2187.2:2006** | Australia | Follows DIN 4150-3 for heritage | 10-50 mm/s (freq dependent) | 25-50 mm/s |
| **FHWA/FTA** | USA | 0.08 in/s (2 mm/s) ancient ruins, 0.12 in/s (3 mm/s) historic | 0.2 in/s (5 mm/s) | 0.5 in/s (12.7 mm/s) |
| **ISO 4866:2010** | International | Framework standard (no specific limits, references DIN/BS) | Framework only | Framework only |
| **Eurocode 8** | EU | Seismic design basis, not vibration limits | Design-focused | Design-focused |
| **AASHTO** | USA (transport) | Project-specific | 0.2 in/s typical | 0.5 in/s typical |

### 5.2 DIN 4150-3: 2016 vs 1999 Differences

The 2016 update to DIN 4150-3:
- Clarified measurement procedures for short-term vs. continuous vibration
- Added more detailed guidance for "structures of great intrinsic value" (Line 3)
- Maintained the same PPV limit values
- Heritage limits remain the most conservative of all international standards:
  - **1-10 Hz: 3 mm/s PPV** (currently implemented in AncientVision)
  - **10-50 Hz: 3-8 mm/s PPV** (linearly interpolated)
  - **50-100 Hz: 8-10 mm/s PPV**
  - **Continuous vibration: 2.5 mm/s PPV** (all frequencies)

### 5.3 BS 7385-2:1993

**Key Difference from DIN**: No specific heritage building category. All buildings treated as either:
- Type 1: Reinforced or framed (15 mm/s at 4Hz, rising to 50 mm/s at 40Hz+)
- Type 2: Unreinforced or light-framed (same limits but with 50% reduction for cosmetic damage)

**Most permissive standard** -- not suitable for heritage protection without modification.

### 5.4 ISO 4866:2010

- International framework standard for vibration measurement of fixed structures
- Explicitly mentions "structures of archaeological and historical value (cultural heritage)"
- Defines measurement methodology but references DIN/BS for actual limits
- Specifies FFT for dominant frequency determination
- Requires tri-axial PPV measurement
- Mandates baseline (pre-construction) survey

### 5.5 FHWA/FTA Guidelines (USA)

Building Category IV (very sensitive to vibration, objects of historic interest):
- **Damage threshold: 0.12 in/s (3.0 mm/s)**
- **Ancient ruins: 0.08 in/s (2.0 mm/s)**
- Non-impact continuous equipment: 0.10 in/s (2.5 mm/s)

### 5.6 Frequency Weighting Curves (ISO 2631)

- **Wk**: Vertical (z-axis) whole-body vibration (most sensitive: 4-8 Hz)
- **Wd**: Horizontal (x,y-axis) whole-body vibration (most sensitive: 1-2 Hz)
- **Wf**: Motion sickness (0.1-0.5 Hz)

These are for human comfort, not structural damage, but useful for understanding worker safety at excavation sites.

### 5.7 Cumulative Damage Models

#### Palmgren-Miner Rule
```
D = sum(i=1..k)[ n_i / N_i ]
Failure when D >= 1.0
```
Where n_i = actual cycles at stress level i, N_i = cycles to failure at stress level i.

**Limitations for Heritage**: Miner's Rule assumes linear damage accumulation and doesn't account for:
- Crack propagation (Paris' Law is better)
- Corrosion-fatigue interaction
- Complex masonry failure mechanisms
- Order-dependent damage (high-low vs low-high loading sequences)

**Alternative**: Separate crack initiation (S-N curves) and crack growth (fracture mechanics with stress intensity factors).

**Recommendation for AncientVision**: Implement simplified Palmgren-Miner cumulative damage tracking. Each vibration event contributes a damage fraction based on its PPV and duration relative to DIN 4150-3 limits. Track cumulative damage index over time.

---

## 6. Archaeological/Heritage Vibration Research

### 6.1 Key Case Studies

#### Colosseum, Rome
- Ambient and traffic-induced vibration analysis of the tallest remaining wall
- Natural frequency identification via OMA
- Traffic from Via dei Fori Imperiali identified as primary vibration source
- Led to periodic traffic restrictions

#### Circus Maximus, Rome
- Torre della Moletta and archaeological ruins monitored during large events (pop concerts, sports celebrations)
- Anthropic vibration (crowd jumping) reached concerning levels
- Study by Geosciences journal (MDPI, 2021)

#### Villa dei Misteri, Pompeii
- Multidisciplinary approach evaluating structural health of protecting roofs
- Vibration monitoring combined with material testing
- UNESCO World Heritage Site protection framework

#### Temple of Hera, Paestum (UNESCO)
- Preliminary vibration monitoring system design for ancient Greek temple
- Located in UNESCO Paestum-Velia archaeological Park
- High-sensitivity large-band sensors deployed

#### Neptune Temple, Paestum
- Innovative monitoring by University of Salerno and Archaeological Park
- Ambient vibration-based modal analysis
- Long-term monitoring strategy development

### 6.2 ICOMOS Charter for Archaeological Heritage (1990)

**Key Principles**:
- Archaeological heritage is non-renewable -- any damage is irreversible
- Protection must be integrated into planning policies
- Monitoring should be continuous and non-destructive
- International cooperation in heritage management

**Vibration Protection**: ICOMOS standards state historic towns should be "protected against natural disasters and nuisances such as pollution and vibrations."

### 6.3 UNESCO Guidelines

UNESCO World Heritage Convention requires:
- Management plans including vibration risk assessment
- Buffer zones around heritage sites
- Environmental impact assessments for nearby construction
- Monitoring and reporting obligations

### 6.4 Vibration Damage Mechanisms by Material

| Material | Primary Failure Mode | Critical PPV | Critical Frequency |
|----------|---------------------|--------------|-------------------|
| **Stone (marble, limestone)** | Joint loosening, spalling | 2-3 mm/s | 1-10 Hz (resonance) |
| **Brick masonry** | Mortar deterioration, crack widening | 3-5 mm/s | 4-15 Hz |
| **Adobe/mud-brick** | Wall delamination, crumbling | 1-2 mm/s | 2-8 Hz |
| **Wood** | Joint loosening, nail withdrawal | 5-8 mm/s | Variable |
| **Plaster/fresco** | Delamination, flaking | 0.5-2 mm/s | All frequencies |
| **Mosaic** | Tessera displacement | 1-3 mm/s | All frequencies |

### 6.5 Soil-Structure Interaction

- Soft soils amplify vibrations (HVSR amplification factors of 2-10x)
- Clay soils show frequency-dependent amplification
- Soil moisture significantly affects vibration transmission velocity
- Water table depth affects site amplification

### 6.6 Ground-Borne Vibration Propagation

**Attenuation Model**:
```
v(r) = v0 * (r0/r)^n * exp(-alpha*(r-r0))
```
Where:
- r = distance from source
- n = geometric spreading exponent (0.5 surface waves, 1.0 body waves)
- alpha = material damping coefficient (0.01-0.1 per meter)

**Practical Implication**: Vibration attenuates with distance. Construction 50m away produces roughly 50-70% less vibration than at 10m.

---

## 7. Advanced PPV and Velocity Analysis

### 7.1 True PPV vs Pseudo-Velocity Spectrum (PSV)

- **True PPV**: Maximum particle velocity in time domain (what we currently measure)
- **PSV**: Pseudo-velocity from response spectrum, PSV = omega * Sd (angular frequency x spectral displacement)
- PSV and true velocity spectra agree within ~15% for typical damping ratios

### 7.2 Peak Vector Sum (PVS) vs PCPV

- **PVS**: sqrt(vx(t)^2 + vy(t)^2 + vz(t)^2) at each time instant, take max
- **PCPV** (Peak Component Particle Velocity): max(peak_vx, peak_vy, peak_vz) -- currently implemented
- **PVS >= PCPV** always (by Cauchy-Schwarz inequality)
- PVS is more physically meaningful but DIN 4150-3 uses PCPV
- Some standards (Australian) use PVS

**Recommendation**: Continue with PCPV for DIN 4150-3 compliance. Add PVS calculation for additional context.

### 7.3 Velocity Integration Methods

#### Currently Implemented: Trapezoidal Integration
```
v(n) = v(n-1) + (a(n) + a(n-1)) * dt / 2
```

#### Simpson's Rule (Higher Accuracy)
```
v(n) = v(n-2) + (a(n-2) + 4*a(n-1) + a(n)) * dt / 3
```

#### Frequency-Domain Integration
```
V(f) = A(f) / (j*2*pi*f)       (division by j*omega in frequency domain)
v(t) = IFFT(V(f))
```
**Advantage**: Naturally avoids DC drift because division by zero at f=0 is handled explicitly.

**Recommendation**: Implement frequency-domain integration on mobile for post-processing analysis. Keep trapezoidal on ESP32 for real-time.

### 7.4 Drift Removal Techniques

- **Current**: 2nd-order Butterworth HPF at 0.3Hz
- **Alternative 1**: Polynomial baseline fitting (fit and subtract low-order polynomial)
- **Alternative 2**: Frequency-domain integration (inherent drift-free)
- **Alternative 3**: Multi-rate HPF (0.1Hz for low-frequency seismic, 0.5Hz for machinery)

### 7.5 Double Integration (Displacement from Acceleration)

```
x(t) = double_integral(a(t))
```
Extremely drift-prone. Requires:
1. Aggressive high-pass filtering (> 0.5 Hz cutoff)
2. Baseline correction at each integration stage
3. Windowing to limit error accumulation

**Archaeological Use**: Displacement is the ultimate damage metric. DIN 4150-3 also specifies displacement limits for continuous vibration.

### 7.6 Arias Intensity

```
Ia = (pi / 2g) * integral(0..T)[ a(t)^2 dt ]
```
**Properties**: Captures amplitude, frequency content, AND duration in a single scalar. Strongly correlated with damage potential.

**Implementability**: ESP32 (trivial -- running sum of squared acceleration), Mobile (yes)

**Recommendation**: Add Arias Intensity computation to ESP32 firmware as an additional damage metric.

### 7.7 Cumulative Absolute Velocity (CAV)

```
CAV = integral(0..T)[ |a(t)| dt ]
```
**Standardized CAV** (EPRI): Only accumulates when 1-second average exceeds 0.025g threshold.

**Advantage**: Single number representing total seismic energy exposure. Used as nuclear power plant shutdown criterion (CAV > 0.16 g-s).

**Implementability**: ESP32 (trivial), Mobile (yes)

**Recommendation**: Implement both CAV and Standardized CAV on ESP32. These are computationally free and provide valuable cumulative damage indicators.

### 7.8 Housner Spectral Intensity

```
SI = integral(0.1s..2.5s)[ PSV(T, 5%) dT ]
```
Integral of pseudo-spectral velocity between 0.1s and 2.5s period (0.4-10 Hz frequency range).

**Key Finding**: Among integral intensity measures, Housner intensity showed the strongest correlation with observed structural damage -- stronger than PGA, Arias intensity, or CAV.

**Implementability**: Mobile (requires response spectrum computation), ESP32 (no)

### 7.9 Response Spectrum Computation

For each natural period T (or frequency f):
1. Compute response of SDOF oscillator with period T and 5% damping
2. Record maximum displacement Sd, velocity Sv, acceleration Sa
3. Plot Sd, PSV, PSA vs T

**Implementability**: Mobile (moderate computation), ESP32 (not real-time but possible for selected periods)

### 7.10 Coherence Function

```
Cxy(f) = |Gxy(f)|^2 / (Gxx(f) * Gyy(f))
```
Measures linear correlation between two signals at each frequency. Range 0-1.

**Use**: Verify sensor coupling quality, identify correlated vibration sources between measurement points.

---

## 8. ESP32/MEMS Accelerometer Optimization

### 8.1 MEMS Accelerometer Comparison

| Parameter | MPU6886 (Current) | BMI270 | ADXL355 |
|-----------|-------------------|--------|---------|
| **Noise Density** | ~400 ug/sqrt(Hz) | 160 ug/sqrt(Hz) | 25 ug/sqrt(Hz) |
| **Resolution** | 16-bit | 16-bit | 20-bit |
| **Range** | +/-8g (configurable) | +/-16g | +/-2g/4g/8g |
| **Bandwidth** | 1.1 kHz | 1.6 kHz | 1 kHz |
| **Power** | ~0.5 mA | ~0.2 mA | 0.2 mA |
| **Interface** | I2C/SPI | I2C/SPI | SPI |
| **Cost** | ~$1-2 | ~$3-5 | ~$15-20 |
| **SHM Suitability** | Low-Medium | Medium | High |
| **Noise Floor (at 200Hz BW)** | ~5.7 mg | ~2.3 mg | ~0.35 mg |

**Key Insight**: The MPU6886 noise density of ~400 ug/sqrt(Hz) limits sensitivity to about 5.7 mg at 200Hz bandwidth. For DIN 4150-3 heritage limits of 3 mm/s PPV at 10 Hz, the minimum detectable acceleration is 0.3 mm/s * 2*pi*10 = 0.019 g = 19 mg, well above the noise floor. The MPU6886 is adequate for the current use case but insufficient for ambient noise HVSR measurements.

**ADXL355 Advantage**: 16x lower noise enables:
- HVSR site characterization
- Sub-mm/s velocity measurements
- Ambient vibration modal analysis
- But requires SPI interface (not available on M5StickC Plus 2 via Grove port)

### 8.2 Oversampling and Decimation

**Principle**: Sample at N times the desired rate, then average N samples. Improves SNR by sqrt(N).

**Current**: 200 Hz sampling, 99 Hz DLPF
**Proposal**: Sample at 800 Hz, decimate by 4 with CIC or FIR filter:
- SNR improvement: sqrt(4) = 2x = 6 dB
- Effective noise density: ~200 ug/sqrt(Hz)
- Cost: Higher CPU usage, more I2C bandwidth

**Implementability**: ESP32 (feasible if using SPI instead of I2C for IMU)

### 8.3 Allan Variance Analysis

**Purpose**: Characterize sensor noise sources from time-domain data.

**Key Parameters from Allan Variance Plot**:
- **Velocity Random Walk (VRW)**: Slope = -0.5, read at tau = 1s
- **Bias Instability**: Minimum of Allan deviation (flat region)
- **Rate Random Walk**: Slope = +0.5
- **Quantization Noise**: Slope = -1

**Procedure**:
1. Collect 1+ hour of static data at maximum sample rate
2. Compute Allan Variance at multiple averaging times
3. Fit noise model parameters

**Recommendation**: Run Allan Variance characterization of the specific MPU6886 unit. Use results to set optimal Kalman filter process noise parameters.

### 8.4 Temperature Compensation

MPU6886 has internal temperature sensor. Bias drift with temperature is typically 0.5-2 mg/degC.

**Procedure**:
1. Collect static data across temperature range (e.g., 10-40C)
2. Fit polynomial: bias(T) = a0 + a1*T + a2*T^2
3. Subtract temperature-dependent bias in real-time

**Implementability**: ESP32 (yes, polynomial evaluation is trivial)

### 8.5 DMA-Based Sampling for Jitter-Free Acquisition

**Current Challenge**: FreeRTOS task scheduling introduces timing jitter in I2C reads.

**Solution Options**:
1. **GPIO interrupt on IMU DRDY pin**: IMU generates interrupt when data ready, ISR reads immediately
2. **SPI with DMA**: Once started, handles transfer without CPU involvement (~2us per transaction)
3. **I2S peripheral with DMA**: Supports DMA streaming without per-sample CPU involvement
4. **Double buffering**: Dedicate one buffer for IMU reads (ISR context), another for processing (task context)

**ESP Timer Caveat**: Callbacks are serialized -- expect jitter during concurrent callbacks.

**Recommendation**: Use DRDY interrupt + SPI for minimum jitter. If stuck with I2C, use high-priority FreeRTOS task with `vTaskDelayUntil()` for most consistent timing.

### 8.6 FreeRTOS Task Prioritization

```
Priority hierarchy:
1. IMU data acquisition (highest -- ISR or priority 5)
2. DSP processing (FFT, filtering) (priority 4)
3. BLE transmission (priority 3)
4. Display update (priority 2)
5. Button handling, LED (priority 1)
```

### 8.7 ESP32-S3 AI Acceleration

If upgrading to ESP32-S3:
- **SIMD vector instructions**: Up to 512-bit vectors
- **ESP-DL library**: Optimized NN inference APIs
- **Performance**: 6.25x speedup for 16-bit models, 2.5x for 8-bit
- **ESP-NN / ESP-DSP**: SIMD-optimized DSP and neural network operations
- **Dual-core LX7 at 240 MHz**: More processing headroom

### 8.8 Power Management for Long-Term Operation

**M5StickC Plus 2 Battery**: 200 mAh
**Current Consumption**: ~80-120 mA (WiFi/BLE active + IMU + display)
**Runtime**: ~1.5-2.5 hours

**Optimization Strategies**:
- Duty cycling: Sample for 5s every 30s (reduce power by ~80%)
- BLE advertising interval: Increase from default to 500ms-2s
- Display timeout: Turn off after 30s
- Deep sleep between sampling windows with RTC wake

**For Extended Monitoring**: External battery pack (10,000 mAh = ~80-100 hours) or USB power.

### 8.9 OTA Firmware Updates

ESP32 supports OTA (Over-The-Air) firmware updates via:
- BLE OTA (slower, ~100 KB/s)
- WiFi OTA (faster, ~1 MB/s)
- Partition scheme: Two app partitions, alternate between them

**Recommendation**: Implement WiFi OTA for field firmware updates without physical access to sensor nodes.

---

## 9. Real-Time Alert Systems

### 9.1 USGS ShakeAlert Architecture

**System Components**:
1. Dense network of seismometers detect P-waves
2. Central processing algorithms estimate magnitude, location, and shaking intensity
3. Alerts distributed to users before damaging S-waves arrive
4. Typical warning time: 5-30 seconds depending on distance

**P-wave vs S-wave**:
- P-waves travel at ~6 km/s (cause minor shaking)
- S-waves travel at ~3.5 km/s (cause major damage)
- Time gap = distance / 3.5 - distance / 6

### 9.2 P-Wave Early Warning Implementation

**For AncientVision**:
1. ESP32 detects sudden acceleration onset via STA/LTA
2. Classify as P-wave if: (a) impulsive onset, (b) dominant frequency 1-20 Hz, (c) amplitude below damage threshold initially
3. Estimate magnitude from initial P-wave amplitude (empirical relation)
4. If estimated magnitude > threshold, issue pre-alert
5. S-wave arrival expected in: t = distance / (1/Vs - 1/Vp)

**Limitation**: Single-station detection cannot estimate distance accurately. Multi-station network needed for robust early warning.

### 9.3 Alert Fatigue Reduction

**Current AncientVision**: 3-sample persistence trigger, 6-sample cooldown

**Advanced Strategies**:
- **Multi-level alerts**: Green (monitoring) -> Yellow (elevated) -> Orange (warning) -> Red (critical)
- **Contextual suppression**: Higher thresholds during known construction hours
- **Alert aggregation**: Combine multiple sub-threshold events into single summary
- **Confidence scoring**: Include probability estimate with each alert
- **Cooldown escalation**: After 3 alerts in 1 hour, increase threshold by 20%

### 9.4 Crowd-Sourced Seismic Detection

**MyShake (UC Berkeley)**: 200,000+ users, phone MEMS accelerometers
**Earthquake Network**: Million+ users, identified 780+ earthquakes from phone triggers

**Relevance**: AncientVision could contribute data to crowd-sourced networks, while also receiving external earthquake alerts.

### 9.5 Sound-Based and Haptic Alerts

**Recommended Alert Tones**:
- Seismic event: Low-frequency pulse (200 Hz, 100ms on/off)
- Machinery vibration: Continuous medium tone (800 Hz)
- Impact event: Sharp beep (1200 Hz, 50ms)
- Critical damage risk: Alarm siren (alternating 400/800 Hz)

---

## 10. Data Management and Visualization

### 10.1 Time-Series Databases

| Database | Type | Best For | Open Source |
|----------|------|----------|-------------|
| **InfluxDB** | Time-series | IoT sensor data, vibration | Yes |
| **TimescaleDB** | PostgreSQL extension | Complex queries + time-series | Yes |
| **QuestDB** | Columnar time-series | High-ingest rate | Yes |
| **SQLite** | Embedded relational | On-device storage | Yes (current) |

### 10.2 Visualization Recommendations

- **Spectrogram/Waterfall**: STFT-based, shows frequency content evolution over time
- **Orbit plots**: Plot X vs Y acceleration for rotational vibration identification
- **3D vibration**: Plot tri-axial acceleration in 3D space
- **Trend charts**: PPV, frequency, Arias intensity over hours/days
- **Alert timeline**: Vertical markers on time axis showing alert events

### 10.3 Data Compression

For long-term vibration data storage:
- Raw data: 200 Hz * 3 axes * 2 bytes = 1.2 KB/s = 100 MB/day
- Feature summary (per 1.28s window): ~50 bytes = 3.4 MB/day
- Triggered recording: Only store raw data during events

---

## 11. Emerging Technologies (2025-2026)

### 11.1 Laser Doppler Vibrometry (LDV)

- Non-contact vibration measurement with femtometer resolution
- Combined with UAVs for inaccessible heritage structures
- Used for heritage masonry frequency detection
- Cost: $10,000-100,000+ (not practical for AncientVision)

### 11.2 Distributed Acoustic Sensing (DAS)

- Uses existing fiber optic cables as continuous sensor arrays
- Spatial resolution: 1-10 meters
- Range: up to 100 km per interrogator unit
- Emerging application for archaeological site perimeter monitoring

### 11.3 InSAR (Radar Interferometry)

- Satellite-based measurement of ground surface displacement
- mm-level precision over large areas
- Revisit time: days to weeks
- Used for monitoring settlement and deformation at heritage sites
- Combined with in-situ sensors (like AncientVision) for comprehensive monitoring

### 11.4 AR/VR Visualization

- Overlay vibration data on 3D structural models in real-time
- AncientVision already has 3D point cloud capability
- Could extend to show vibration mode shapes overlaid on structure

### 11.5 Digital Twins (Updated)

Current implementations (2025):
- Real-time FE model synchronization with sensor data
- Automatic damage updating via evolutionary optimization
- Bayesian model calibration from heterogeneous data sources
- Concept-drift-adaptive anomaly detection

---

## 12. Vibration Source Characterization

### 12.1 Blind Source Separation (BSS / ICA)

**Technique**: Recover original source signals from mixed observations without knowing the mixing process.

**Algorithms**:
- **FastICA**: Maximizes non-Gaussianity (fast convergence)
- **JADE**: Joint Approximate Diagonalization of Eigenmatrices
- **SOBI**: Second-Order Blind Identification (best for vibration modal coordinates)

**Key Insight**: Modal coordinates are a special case of sources with specific time structure. SOBI is particularly suited for extracting linear normal modes from vibration data.

**Implementability**: Mobile (yes), ESP32 (no -- matrix operations too expensive)

### 12.2 Vibration Source Identification via ML

**Approach**: Train classifier on labeled vibration signatures:
- Traffic (periodic, broadband 5-50 Hz)
- Construction equipment (specific spectral patterns)
- Human activity (random impacts, 2-20 Hz)
- Seismic (impulsive onset, broadband)
- Wind (very low frequency < 2 Hz)

**Implementation**: 1D CNN on ESP32 or mobile, trained on labeled recordings from the specific site.

### 12.3 Beamforming for Source Localization

Requires sensor array (minimum 3 sensors). Not applicable to single-sensor AncientVision but relevant for multi-node deployment.

**Time Difference of Arrival (TDOA)**:
```
delta_t = cross_correlation_peak(sensor_1, sensor_2)
distance_difference = delta_t * v_propagation
```

### 12.4 Vibration Fingerprinting

**Concept**: Each vibration source has a unique spectral "fingerprint":
- Frequency content
- Temporal pattern (periodic, random, transient)
- Crest factor
- Kurtosis profile
- Spectral centroid trajectory

**Application**: Automatically identify what is causing vibration without visual inspection.

---

## Implementation Priority Matrix for AncientVision

### Tier 1: Implement Now (ESP32 Firmware v4.0)
| Feature | Effort | Impact | Notes |
|---------|--------|--------|-------|
| Recursive STA/LTA | Low | Medium | Memory savings over classic |
| Arias Intensity | Low | High | Running sum of a^2, near-zero cost |
| CAV / Standardized CAV | Low | High | Running sum of |a|, near-zero cost |
| NLMS adaptive notch filter | Medium | High | Cancel known interference |
| Temperature compensation | Medium | High | Polynomial bias correction |
| DWT (Haar, 3-level) | Medium | High | Transient detection alongside FFT |
| Palmgren-Miner damage index | Low | High | Cumulative damage tracking |
| PVS (Peak Vector Sum) | Low | Medium | Additional to existing PCPV |

### Tier 2: Implement on Mobile (Flutter App)
| Feature | Effort | Impact | Notes |
|---------|--------|--------|-------|
| VAE upgrade (from AE) | Medium | High | Better anomaly scoring |
| 1D CNN event classifier | Medium | High | Vibration source ID |
| Natural frequency tracking | Medium | Critical | Damage detection gold standard |
| Synchrosqueezed Transform | High | High | Best time-frequency analysis |
| HVSR computation | Medium | High | Site characterization |
| Response spectrum | Medium | Medium | Seismic engineering metric |
| Frequency-domain integration | Medium | Medium | Drift-free velocity |
| Adaptive baseline (EMA) | Medium | High | Concept drift handling |
| Spectrogram visualization | Medium | Medium | Enhanced data display |
| Housner Spectral Intensity | Medium | High | Best damage correlation |

### Tier 3: Future / Research
| Feature | Effort | Impact | Notes |
|---------|--------|--------|-------|
| PhaseNet (TFLite) | High | High | P-wave phase picking |
| Digital twin framework | Very High | Very High | Long-term goal |
| GNN for multi-sensor | High | High | Requires sensor array |
| EMD/HHT analysis | Medium | Medium | Source separation |
| Foundation model inference | High | Medium | Zero-shot forecasting |
| Federated learning | Very High | Medium | Multi-site collaboration |
| PINNs inference | High | High | Physics-constrained prediction |

---

## Key Open-Source Resources

### Signal Processing
- **ObsPy** (Python): docs.obspy.org -- Complete seismology toolkit (STA/LTA, AR-AIC picker, spectral analysis)
- **ssqueezepy** (Python): github.com/OverLordGoldDragon/ssqueezepy -- Synchrosqueezing, wavelet transforms
- **PyWavelets** (Python): pywavelets.readthedocs.io -- DWT, CWT, WPT
- **wavelib** (C): github.com/rafat/wavelib -- Embeddable wavelet library for ESP32
- **fCWT** (C++): github.com/fastlib/fCWT -- Fast CWT
- **PyEMD** (Python): EMD, EEMD, CEEMDAN implementations
- **vmdpy** (Python): VMD implementation

### Machine Learning
- **PhaseNet**: github.com/AI4EPS/PhaseNet -- Deep learning phase picking
- **EQTransformer**: github.com/smousavi05/EQTransformer -- Earthquake detection + phase picking
- **MOMENT**: github.com/moment-timeseries-foundation-model/moment -- Time-series foundation model
- **Chronos**: github.com/amazon-science/chronos-forecasting -- Amazon time-series foundation model
- **Edge Impulse**: edgeimpulse.com -- TinyML platform with ESP32 support
- **TensorFlow Lite Micro**: tensorflow.org/lite/microcontrollers -- On-device ML for ESP32
- **ESP-DL**: github.com/espressif/esp-dl -- Espressif deep learning library

### Seismology
- **Seismic Intensity Measure** (Python): github.com/fiorellalan/Seismic-Intensity-Measure -- PGA, PGV, Arias, CAV, SI, response spectra
- **SeisComP**: seiscomp.de -- Complete seismological software
- **GaMMA**: github.com/AI4EPS/GaMMA -- Gaussian Mixture Model Association

### SHM
- **OpenSees**: opensees.berkeley.edu -- Open System for Earthquake Engineering Simulation
- **ARTeMIS Modal**: svibs.com -- OMA software (commercial, reference implementation)

---

## References Summary

### Foundational Papers
1. Huang, N.E. et al. (1998). "The empirical mode decomposition and the Hilbert spectrum." *Proc. Royal Society A*, 454, 903-995.
2. Dragomiretskiy, K. & Zosso, D. (2014). "Variational Mode Decomposition." *IEEE Trans. Signal Processing*, 62(3), 531-544.
3. Daubechies, I. et al. (2011). "Synchrosqueezed wavelet transforms." *Applied and Computational Harmonic Analysis*, 30(2), 243-261.
4. Antoni, J. (2006). "The spectral kurtosis: a useful tool for characterising non-stationary signals." *Mech. Sys. Signal Proc.*, 20(2), 282-307.
5. Zhu, W. & Beroza, G.C. (2019). "PhaseNet." *Geophysical Journal International*, 216(1), 261-273.
6. Mousavi, S.M. et al. (2020). "Earthquake transformer." *Nature Communications*, 11, 3952.
7. Brincker, R. et al. (2001). "Modal identification of output-only systems using FDD." *Smart Materials and Structures*, 10(3), 441.
8. Worden, K. & Farrar, C.R. (2007). "An introduction to SHM." *Phil. Trans. Royal Society A*, 365(1851), 303-315.
9. Withers, M. et al. (1998). "A comparison of select trigger algorithms." *BSSA*, 88(1), 95-106.
10. Baer, M. & Kradolfer, U. (1987). "An automatic phase picker." *BSSA*, 77(4), 1437-1445.

### Standards
11. DIN 4150-3:2016 -- Vibrations in buildings
12. BS 7385-2:1993 -- Evaluation and measurement of vibration in buildings
13. ISO 4866:2010 -- Vibration of fixed structures
14. SN 640312a -- Swiss vibration standard
15. AS 2187.2:2006 -- Explosives storage and use (Part 2)
16. FHWA-HRT-06-088 -- Highway construction vibration guidance

---

*Document compiled February 2026 for AncientVision FLL Project*
*Research covers literature through January 2026*
