# Pre-Flash Checklist for v4.0 Hardware Demo

**Date**: February 11, 2026
**Hardware**: M5StickC Plus 2 ESP32
**Firmware**: AncientVision v4.0
**App Version**: v4.0 (152.1 MB APK)

---

## ✅ Pre-Flash Preparation (Do Before Hardware Session)

### 1. Software Ready
- [x] ESP32 firmware v4.0 written (`m5stick_firmware/AncientVisionSensor.ino`)
- [x] App v4.0 UI integration complete (Safety tab shows v4.0 metrics)
- [x] ML VAE v4.0 model trained and exported (3 files in `assets/ml/`)
- [x] BLE parser supports v4.0 (17 fields, backward compatible)
- [x] APK built: `build\app\outputs\flutter-apk\app-release.apk` (152.1 MB)
- [x] All 181 unit tests passing
- [x] Zero lint issues

### 2. Arduino IDE Setup
- [ ] Arduino IDE installed (version 1.8.19 or 2.x)
- [ ] ESP32 board support installed (File → Preferences → Additional Boards Manager URLs)
- [ ] M5StickC Plus 2 libraries installed:
  - [ ] `M5StickCPlus2` (or `M5Unified`)
  - [ ] `arduinoFFT` (Arduino Library Manager)
  - [ ] `MadgwickAHRS` (Arduino Library Manager)
- [ ] Board configured: Tools → Board → M5StickC Plus 2 (or M5Stack-Core-ESP32)
- [ ] Upload speed: 921600
- [ ] Flash frequency: 80MHz
- [ ] Partition scheme: Default 4MB with spiffs

### 3. Android Device Ready
- [ ] Device charged (>50%)
- [ ] USB cable available for APK transfer
- [ ] "Install from Unknown Sources" enabled (Settings → Security)
- [ ] Bluetooth enabled and working
- [ ] Previous AncientVision version uninstalled (or ready to update)

### 4. Physical Hardware
- [ ] M5StickC Plus 2 charged (>50%)
- [ ] USB-C cable for M5StickC (good quality, data-capable)
- [ ] M5StickC turns on (hold power button 2 seconds)
- [ ] M5StickC LCD displays correctly

---

## 🔧 Firmware Flash Procedure

### Step 1: Open Firmware in Arduino IDE
1. Launch Arduino IDE
2. File → Open → Navigate to:
   ```
   C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision\m5stick_firmware\AncientVisionSensor.ino
   ```
3. Verify no compile errors (Sketch → Verify/Compile)
4. Expected output: "Done compiling" (~30 seconds)

### Step 2: Connect M5StickC Plus 2
1. Plug USB-C cable into M5StickC
2. Connect to computer USB port
3. Arduino IDE: Tools → Port → Select COM port (e.g., COM3, COM4)
4. If port not detected:
   - Check cable is data-capable (not charge-only)
   - Reinstall CP210x drivers (Silicon Labs)
   - Try different USB port

### Step 3: Upload Firmware
1. Click **Upload** button (→) in Arduino IDE
2. Wait for compilation (~30 seconds)
3. Watch for "Connecting..." message
4. If stuck on "Connecting...":
   - Hold M5StickC power button for 6 seconds (power off)
   - Release, then hold power button 2 seconds (power on)
   - Click Upload again immediately
5. Upload progress: 0% → 100% (~20 seconds)
6. Watch for final message: "Hard resetting via RTS pin..."
7. **Success indicator**: M5StickC reboots automatically

### Step 4: Verify Firmware v4.0
1. M5StickC LCD should display boot screen:
   ```
   AncientVision
   Sensor v4.0
   -----------
   BLE: Ready
   IMU: OK
   Moisture: OK
   ```
2. Press side button (cycle display modes)
3. Display should show:
   - Row 1: X/Y/Z accelerometer (X≈0, Y≈0, Z≈9.8 when flat)
   - Row 2: RMS, PPV, Freq
   - Row 3: Kurt, STA/LTA
   - Row 4: **Arias** (v4.0), **CAV** (v4.0)
   - Row 5: **Temp** (v4.0), Moisture %
   - Row 6: Alert status
4. **v4.0 verification**: If you see Arias, CAV, Temp → firmware v4.0 successful

### Step 5: Test IMU (Optional)
1. Shake M5StickC vigorously
2. Watch values on LCD change:
   - RMS should spike (>0.1)
   - PPV should spike (>10 mm/s)
   - Kurtosis should increase
3. Let sit flat for 5 seconds
4. Values should return to baseline (RMS <0.01, PPV <1)
5. If values don't respond to shaking:
   - Check IMU calibration (firmware auto-calibrates on boot)
   - Reboot M5StickC (hold power 6 sec off, 2 sec on)

---

## 📱 App Installation & Testing

### Step 1: Transfer APK to Android
1. Connect Android device via USB (or use Google Drive/email)
2. Copy APK from:
   ```
   C:\Users\thodo\Desktop\FLL_Thodoris\AncientVisionFLL\AncientVision\build\app\outputs\flutter-apk\app-release.apk
   ```
3. Paste to device Downloads folder
4. Safely eject/disconnect USB

### Step 2: Install APK
1. Open Files app on Android
2. Navigate to Downloads
3. Tap `app-release.apk`
4. If prompted: "Install from Unknown Sources" → Allow
5. Tap **Install**
6. Wait for installation (~10 seconds)
7. Tap **Open** or launch from app drawer

### Step 3: App First Launch
1. Sign in with Firebase credentials
2. Grant permissions when prompted:
   - [ ] Camera (for photogrammetry)
   - [ ] Location (for GPS tagging)
   - [ ] Storage (for saving photos/findings)
   - [ ] Bluetooth (for BLE sensor)
3. Navigate to **Safety** tab (shield icon)

### Step 4: BLE Connection Test
1. In Safety tab, tap **"Scan for Sensors"**
2. M5StickC should appear: "M5Stick Ancient Vision"
3. Tap to connect
4. Watch connection process:
   - "Connecting..."
   - "Negotiating MTU..." (may take 5-10 seconds)
   - "Discovering services..."
   - "Connected" ✓
5. If MTU negotiation fails:
   - Ignore warning, connection should still work
   - Data will be truncated but parseable
6. **Connection success**: Green "CONNECTED" chip at top

### Step 5: Verify v4.0 Data Reception
1. **v3.0 metrics** (should update every ~1 second):
   - Accelerometer: X/Y/Z values
   - PPV: Peak Particle Velocity (mm/s)
   - RMS: Root Mean Square
   - Frequency: Dominant frequency (Hz)
   - Crest Factor: Peak/RMS ratio
   - Kurtosis: Impact indicator
   - STA/LTA: Seismic event ratio
   - Centroid: Spectral centroid (Hz)

2. **v4.0 NEW metrics** (verify these appear):
   - [ ] **Arias Intensity** (m/s, typically 0.0000-0.0100)
   - [ ] **CAV** (g·s, typically 0.000-0.500)
     - Orange if >0.1 g·s
     - Red if >0.16 g·s (EPRI damage threshold)
   - [ ] **Temperature** (°C, typically 20-30°C)
   - [ ] **DWT panel** (3 colored bars):
     - D1 (50-100Hz) - Green bar
     - D2 (25-50Hz) - Orange bar
     - D3 (12-25Hz) - Red bar

3. **Visual check**: Look for "Wavelet Decomposition (DWT)" section below main metrics

### Step 6: Alert System Test
1. Shake M5StickC Plus 2 vigorously (simulate vibration)
2. Expected response (5-10 seconds):
   - PPV should spike >3 mm/s (heritage limit)
   - Alert state changes from "Safe" → "Warning" → "Alert"
   - **Full-screen alert overlay** appears (red background)
   - Audio alarm sounds (if not muted)
   - M5StickC LCD shows "ALERT" message
3. Stop shaking, let sit flat
4. Alert should clear after ~10 seconds (hysteresis)
5. Test **Mute** button (top right):
   - Tap mute → speaker icon crossed out
   - Shake again → visual alert only (no audio)
   - Tap unmute → audio returns

### Step 7: ML Anomaly Detection Test
1. Watch for **ML Anomaly Indicator** in Safety tab
2. Normal vibration: Green "Normal" chip
3. Shake M5StickC in unusual pattern (rapid on/off)
4. ML score should increase (>threshold triggers anomaly)
5. If anomaly detected: Yellow/Orange "Anomaly Detected" chip
6. **v4.0 VAE model**: Uses 10 features (arias, cav, temp included)

---

## 🔬 Advanced Verification (Optional)

### Photogrammetry Test
1. Navigate to **Tools** tab
2. Tap "Photogrammetry Capture"
3. Grant camera permission
4. Follow 12-angle capture guide
5. Verify photos save to gallery
6. Check 3D reconstruction preview

### Manual Entry Form
1. Navigate to **Tools** tab
2. Tap "Manual Entry"
3. Fill artifact details
4. Add GPS location
5. Save to Firebase
6. Verify appears in **Findings** tab

### Findings Map
1. Navigate to **Findings** tab
2. Tap map icon (top right)
3. Verify findings display on map
4. Test tap-to-view details

---

## ❌ Rollback Plan (If v4.0 Fails)

### Option 1: Revert Firmware Only
- If v4.0 firmware has issues but app works fine
- Flash v3.0 firmware from Git history
- App v4.0 is backward compatible (v4.0 fields default to 0)
- Will lose: Arias, CAV, Temp, DWT visualization

### Option 2: Revert App Only
- If app v4.0 has UI issues
- Uninstall current APK
- Reinstall previous version from backup
- Firmware v4.0 will still work (extra fields ignored)

### Option 3: Full Rollback
- Flash v3.0 firmware
- Install v3.0 app
- Everything returns to pre-upgrade state

---

## 📊 Expected v4.0 Baseline Values

When M5StickC is sitting flat on table:

| Metric | Expected Value | Units |
|--------|---------------|-------|
| X accel | -0.1 to +0.1 | g |
| Y accel | -0.1 to +0.1 | g |
| Z accel | 9.6 to 10.0 | g |
| RMS | <0.01 | g |
| PPV | 0.0 to 1.0 | mm/s |
| Frequency | 0 to 20 | Hz |
| Crest | 1.0 to 3.0 | ratio |
| Kurtosis | -0.5 to 0.5 | excess |
| STA/LTA | 0.8 to 1.2 | ratio |
| Centroid | 0 to 30 | Hz |
| **Arias** (v4.0) | 0.0000 to 0.0001 | m/s |
| **CAV** (v4.0) | 0.000 to 0.005 | g·s |
| **Temp** (v4.0) | 20 to 30 | °C |
| **DWT1-3** (v4.0) | <0.001 | g |

When shaken vigorously:

| Metric | Expected Value | Units |
|--------|---------------|-------|
| RMS | 0.1 to 0.5 | g |
| PPV | 10 to 100 | mm/s |
| Frequency | 10 to 80 | Hz |
| Crest | 3 to 8 | ratio |
| Kurtosis | 3 to 10 | excess |
| STA/LTA | 2 to 8 | ratio |
| **Arias** (v4.0) | 0.001 to 0.050 | m/s |
| **CAV** (v4.0) | 0.01 to 0.20 | g·s |

---

## 🐛 Common Issues & Fixes

### Issue: "Sketch too large"
- **Fix**: Tools → Partition Scheme → "Huge APP (3MB No OTA)"

### Issue: M5StickC not detected
- **Fix**: Install CP210x USB drivers from Silicon Labs
- **Fix**: Try different USB cable (must be data-capable)

### Issue: Stuck on "Connecting..." during upload
- **Fix**: Power cycle M5StickC (hold power 6 sec off, 2 sec on)
- **Fix**: Press Upload button immediately after power on

### Issue: BLE connection fails in app
- **Fix**: Restart Bluetooth on Android
- **Fix**: Move devices closer (<2 meters)
- **Fix**: Restart M5StickC
- **Fix**: Clear app data (Settings → Apps → AncientVision → Clear Data)

### Issue: v4.0 metrics show 0.000
- **Possible causes**:
  1. Firmware is still v3.0 (check LCD boot screen)
  2. BLE payload truncated (check MTU negotiation)
  3. IMU not initialized (reboot M5StickC)

### Issue: DWT bars not visible
- **Expected**: DWT values are very small when stationary (<0.001)
- **Test**: Shake M5StickC → bars should grow
- **Fix**: If still 0, firmware may not have v4.0 DWT code

### Issue: ML anomaly always "Normal"
- **Expected**: Normal state is correct when no anomalies
- **Test**: Shake in unusual pattern (rapid start/stop)
- **Fix**: Check model files exist in `assets/ml/` (3 files)

---

## ✅ Success Criteria

After completing this checklist, you should have:

1. [x] **Firmware v4.0** flashed to M5StickC Plus 2
   - Boot screen shows "v4.0"
   - LCD displays 17 fields (including Arias, CAV, Temp)

2. [x] **App v4.0** installed on Android
   - APK version 152.1 MB
   - Safety tab shows v4.0 metrics
   - DWT visualization panel present

3. [x] **BLE connection** working
   - "Connected" status in Safety tab
   - Live data updating every ~1 second
   - All v4.0 fields non-zero when shaken

4. [x] **Alert system** functional
   - Full-screen alert on vibration >3 mm/s
   - Audio alarm sounds
   - Mute button works

5. [x] **ML anomaly detection** operational
   - VAE v4.0 model loads
   - Anomaly score updates
   - Unusual vibration triggers alert

6. [x] **End-to-end test** passed
   - Shake M5StickC → see data in app
   - Alert triggers → full-screen overlay appears
   - ML detects anomaly → indicator changes color
   - All v4.0 metrics display correctly

---

## 📝 Post-Flash Notes

**Record after successful flash:**

- Flash date/time: _______________
- M5StickC battery: _______________
- Android device model: _______________
- BLE connection quality: Excellent / Good / Fair / Poor
- Any warnings during upload: _______________
- Any issues encountered: _______________
- v4.0 metrics verified: Yes / No
- Alert system tested: Yes / No
- Demo-ready: Yes / No

**Backup reminder:**
- Git commit hash of deployed firmware: `ff85ce8`
- APK backup location: `build\app\outputs\flutter-apk\app-release.apk`
- Rollback firmware available at: Git tag `v3.0` (if needed)

---

**Prepared by**: Claude Sonnet 4.5
**Date**: February 10, 2026
**Project**: AncientVision FLL Archaeological Monitoring System
**Next milestone**: FLL Demo (March 2026)
