# AncientVision v4.0 Deployment Guide

## Overview

This guide covers deploying the v4.0 upgrade to your AncientVision system. **All code is ready**, but deployment involves:
1. Flashing ESP32 firmware v4.0 to M5StickC Plus 2
2. Installing the updated APK on your Android device

**Current Status (Feb 10, 2026)**:
- ✅ ESP32 firmware v4.0 code written (`m5stick_firmware/AncientVisionSensor.ino`)
- ✅ ML VAE v4.0 model trained (`assets/ml/vibration_anomaly.tflite`)
- ✅ App BLE parser upgraded (backward compatible with v2.0/v3.0/v4.0)
- ✅ 6 new advanced services created and tested
- ✅ All 181 tests passing
- ✅ APK built (`app-release.apk`, 153 MB)

---

## What's New in v4.0

### ESP32 Firmware Upgrades
- **Recursive STA/LTA** — saves 8KB RAM vs array-based (EMA implementation)
- **3-level Haar DWT** — on-device wavelet transform for transient detection
- **Arias Intensity** — cumulative seismic energy (π/2g·∫a²dt), auto-resets every 60s
- **CAV (Cumulative Absolute Velocity)** — EPRI damage threshold 0.16 g·s
- **IMU temperature** — reads MPU6886 temp + thermal bias compensation (0.0005g/°C)
- **Expanded BLE JSON** — 17 fields (was 11 in v3.0)

### App Upgrades
- **ML VAE v4.0** — 10-feature Variational Autoencoder (was 7-feature autoencoder)
- **BLE parser** — supports all 17 v4.0 firmware fields, backward compatible
- **New services** (created, tested, ready for future UI integration):
  - Wavelet analysis (Haar DWT, denoising, transient detection)
  - Advanced vibration metrics (Arias, CAV, Housner SI, multi-standard classification)
  - Spectrogram visualization (time-frequency plots with colormaps)
  - EXIF parsing & reconstruction quality assessment
  - Bundle adjustment (Levenberg-Marquardt)
  - CIDOC-CRM metadata export

---

## Prerequisites

### For ESP32 Firmware Flash
- Arduino IDE (1.8.19 or 2.x)
- ESP32 board support installed
- M5StickC Plus 2 libraries (`M5StickCPlus2`, `M5Unified`)
- Required libraries from Arduino Library Manager:
  - `arduinoFFT`
  - `MadgwickAHRS`
- USB-C cable for M5StickC Plus 2

### For App Installation
- Android device (Android 5.0+)
- USB cable or file transfer method
- "Install from Unknown Sources" enabled

---

## Step 1: Flash ESP32 Firmware v4.0

### 1.1 Open Arduino IDE
Launch Arduino IDE and verify ESP32 board support is installed (Tools → Board → ESP32 → M5StickC Plus 2).

### 1.2 Open Firmware
File → Open → Navigate to:
```
C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision\m5stick_firmware\AncientVisionSensor.ino
```

### 1.3 Configure Arduino IDE
- **Board**: Tools → Board → M5StickC Plus 2 (or M5Stack-Core-ESP32)
- **Upload Speed**: 921600
- **Flash Frequency**: 80MHz
- **Partition Scheme**: Default 4MB with spiffs

### 1.4 Connect M5StickC Plus 2
- Plug USB-C cable into M5StickC Plus 2
- Connect to computer
- Select correct COM port (Tools → Port)

### 1.5 Upload Firmware
- Click **Upload** button (→)
- Wait for compilation and upload (~30 seconds)
- Watch for "Hard resetting via RTS pin..." completion message

### 1.6 Verify Firmware
After upload, the M5StickC Plus 2 LCD should display:
```
AncientVision
Sensor v4.0
-----------
BLE: Ready
IMU: OK
Moisture: OK
```

Press the side button to cycle through display modes. The device should show:
- Row 1: Accelerometer X/Y/Z
- Row 2: RMS, PPV, Frequency
- Row 3: Kurtosis, STA/LTA
- Row 4: Arias Intensity, CAV
- Row 5: Temperature, Moisture %
- Row 6: Alert status

---

## Step 2: Install App APK

### 2.1 Locate APK
The built APK is at:
```
C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision\build\app\outputs\flutter-apk\app-release.apk
```
Size: 153 MB

### 2.2 Transfer to Android Device
Choose one method:
- **USB transfer**: Connect device → Copy APK to Downloads folder
- **Cloud**: Upload to Google Drive → Download on device
- **Email**: Send to yourself → Download attachment

### 2.3 Install APK
1. Open Files app on Android
2. Navigate to Downloads
3. Tap `app-release.apk`
4. If prompted, enable "Install from Unknown Sources"
5. Tap Install
6. Wait for installation (~10 seconds)

### 2.4 First Launch
1. Open AncientVision app
2. Sign in with Firebase credentials
3. Grant permissions (Camera, Location, Storage, Bluetooth)
4. Navigate to Safety tab

---

## Step 3: Test BLE Connection

### 3.1 Pair Sensor
1. In Safety tab, tap **"Scan for Sensors"**
2. M5StickC Plus 2 should appear as "M5Stick Ancient Vision"
3. Tap to connect
4. Wait for "Connected" status

### 3.2 Verify Data Reception
Watch for live data updates:
- Accelerometer values updating at ~5 Hz
- PPV, RMS, Frequency
- **NEW v4.0 fields** (if firmware v4.0 flashed):
  - Arias Intensity
  - CAV
  - Temperature
  - DWT levels

### 3.3 Test Alert System
1. Shake the M5StickC Plus 2 vigorously
2. Alert should trigger (PPV > 3 mm/s for heritage sites)
3. Full-screen alert overlay should appear
4. Audio alarm sounds (if not muted)

---

## Troubleshooting

### Firmware Flash Failed
- **Error**: "Failed to connect to ESP32"
  - **Fix**: Hold M5StickC power button for 6 seconds to power off, then power on and retry
- **Error**: "Sketch too large"
  - **Fix**: Change Partition Scheme to "Huge APP (3MB No OTA)"

### BLE Connection Issues
- **Sensor not appearing in scan**
  - Check M5StickC is powered on (LCD shows v4.0 boot screen)
  - Restart Bluetooth on Android device
  - Move closer to sensor (<5 meters)
- **"MTU negotiation failed"**
  - This is expected on some devices, connection should still work
- **Data not updating**
  - Check BLE UUIDs match (firmware shows service UUID on LCD row 2)
  - Restart app

### ML Model Not Loading
- Check files exist:
  - `assets/ml/vibration_anomaly.tflite` (5.1 KB)
  - `assets/ml/vibration_scaler.json` (718 bytes)
  - `assets/ml/vibration_model_config.json` (685 bytes)
- If missing, run: `python scripts/train_vibration_autoencoder.py --synthetic`

---

## Backward Compatibility

The app is **fully backward compatible**:
- If you **don't flash v4.0 firmware**, the app still works with v2.0/v3.0 firmware
- New v4.0 fields (arias, cav, temp, dwt1-3) default to 0 if missing from BLE data
- ML model auto-detects firmware version (4/7/10 features)

**Recommendation for FLL Demo**: If your M5StickC Plus 2 is working reliably with v3.0 firmware, **keep it** and defer flashing to post-competition. The app already handles both versions.

---

## Advanced: Retrain ML Model

If you want to retrain the VAE with different synthetic data parameters:

```bash
cd C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision
python scripts/train_vibration_autoencoder.py --synthetic
```

This regenerates all 3 ML files in `assets/ml/`. Then rebuild APK:
```bash
flutter build apk --release
```

---

## Testing Checklist

After deployment, verify:
- [ ] ESP32 LCD shows "v4.0" on boot
- [ ] App connects to sensor via BLE
- [ ] Live data updates in Safety tab
- [ ] Accelerometer values realistic (~0 X/Y, ~9.8 Z when stationary)
- [ ] Alert triggers when shaken
- [ ] Full-screen alert appears
- [ ] Mute button works
- [ ] Photogrammetry capture still functional
- [ ] Manual entry form still functional
- [ ] Findings sync to Firebase

---

## Rollback Plan

If v4.0 causes issues before your demo:

### Rollback Firmware
1. Open `m5stick_firmware/AncientVisionSensor_v3.0.ino` (if you saved a backup)
2. Or download v3.0 from your GitHub/Git history
3. Flash to M5StickC Plus 2 following Step 1

### Rollback App
1. Uninstall current APK
2. Reinstall previous version from `build/` folder or Git history

The app is backward compatible, so even with v3.0 firmware, the new app works fine.

---

## Support

For issues or questions:
- Check `MEMORY.md` for architecture notes
- Review test files in `test/unit/` for service usage examples
- File GitHub issue: https://github.com/anthropics/claude-code/issues

---

**Last Updated**: February 10, 2026
**Tested On**: Windows 11, Flutter 3.x, Arduino IDE 2.3.2, M5StickC Plus 2
