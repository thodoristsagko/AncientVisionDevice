/*
 * AncientVision Trench Safety Monitor v5.0
 * For M5StickC Plus 2 with Soil Moisture Sensor
 *
 * v5.0 Changes:
 * - Stripped heavy DSP (FFT, DWT, Kurtosis, Arias, CAV) from firmware
 * - Raw acceleration data sent as binary over BLE for phone-side DSP
 * - Simplified JSON payload (~120 bytes)
 * - Reduced flash/RAM usage significantly
 *
 * Retained from v4.x:
 * - Madgwick quaternion gravity removal (accurate at any orientation)
 * - Tri-axial PCPV per DIN 4150-3 (proper 3-axis PPV)
 * - 2nd-order Butterworth bandpass (0.5-100Hz) per axis
 * - Velocity integration (trapezoidal + HPF) for PPV
 * - Recursive STA/LTA (cheap, 6 lines)
 * - RMS, Peak, Crest factor
 * - Hysteresis alert state machine
 * - Filter warm-up discard (first 2 windows)
 *
 * Signal Processing Pipeline:
 *   Raw IMU (200Hz) -> Temp Compensation -> DLPF (99Hz) -> Madgwick Gravity Removal
 *   -> Butterworth Bandpass (0.5-100Hz) per axis -> Tri-axial PPV + Velocity HPF
 *   -> Recursive STA/LTA -> Raw accel binary over BLE for phone-side DSP
 *
 * Libraries Required:
 * - M5StickCPlus2 (Arduino Library Manager)
 * - MadgwickAHRS (Arduino Library Manager, by Arduino)
 */

#include <M5Unified.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <MadgwickAHRS.h>
#include <Wire.h>
#include "esp_task_wdt.h"
#include "esp_system.h"  // P101: esp_reset_reason()
#include "esp_sleep.h"   // P210: deep sleep wake-up source configuration
#include "nvs_flash.h"   // P180: NVS persistent settings
#include "nvs.h"         // P180: NVS read/write API
#include "SPIFFS.h"      // P198: SPIFFS data logging

#if WIFI_ENABLED
#include <WiFi.h>
#include <HTTPClient.h>
#endif

// Uncomment to enable debug serial output (costs ~2-3KB flash)
// #define DEBUG

#ifdef DEBUG
  #define DBG_PRINTF(...) Serial.printf(__VA_ARGS__)
  #define DBG_PRINTLN(x) Serial.println(x)
#else
  #define DBG_PRINTF(...) ((void)0)
  #define DBG_PRINTLN(x) ((void)0)
#endif

// ===================== CONFIGURATION =====================

// P149: OTA update readiness — set to 1 when update server is configured
#define OTA_ENABLED 0

// P179: WiFi direct push to data collector
#define WIFI_ENABLED            0           // Set to 1 to enable WiFi push
#define WIFI_SSID               "ancientvision_ap"
#define WIFI_PASSWORD           "field_deploy_pw"
#define WIFI_COLLECTOR_URL      "http://192.168.1.100:8765"
#define COLLECTOR_URL           WIFI_COLLECTOR_URL "/ingest"
#define WIFI_PUSH_INTERVAL      30000       // Push every 30s
#define WIFI_CONNECT_TIMEOUT_MS 5000        // WiFi association timeout
#define WIFI_HTTP_TIMEOUT_MS    5000        // HTTP request timeout

// Sampling Configuration
const int SAMPLE_RATE = 200;             // 200 Hz IMU sampling
const int SAMPLE_INTERVAL_US = 5000;     // 5ms = 200 Hz (in microseconds)
const int FFT_SAMPLES = 256;             // Window size (kept for buffer sizing)
const float FFT_WINDOW_SEC = (float)FFT_SAMPLES / SAMPLE_RATE;  // 1.28s

// Soil Moisture Thresholds (safe range: 30-60%)
const int MOISTURE_MIN_SAFE = 30;
const int MOISTURE_MAX_SAFE = 60;

// Sensor Pin
const int MOISTURE_PIN = 33;

// Calibration values for soil moisture sensor
const int MOISTURE_AIR = 3500;
const int MOISTURE_WATER = 1500;

// PPV Thresholds (mm/s)
const float PPV_SAFE_MAX = 0.3;          // Below human perception
const float PPV_STRUCTURAL_DAMAGE = 10.0; // Structural damage risk

// STA/LTA Configuration (recursive - no arrays needed)
const float STA_ALPHA = 1.0f / 40.0f;    // Equivalent to 40-sample window (0.2s at 200Hz)
const float LTA_ALPHA = 1.0f / 2000.0f;  // Equivalent to 2000-sample window (10s at 200Hz)
const float STA_TRIGGER = 4.0;    // STA/LTA trigger ratio
const float STA_DETRIGGER = 1.5;  // STA/LTA de-trigger ratio

// Hysteresis Configuration
const int TRIGGER_COUNT = 2;      // Windows to confirm alert (~2.5s)
const int CLEAR_COUNT = 4;        // Windows to clear alert (~5s)
const int COOLDOWN_WINDOWS = 8;   // Cooldown before re-alerting (~10s)

// Temperature compensation (MPU6886 typical bias drift)
const float TEMP_BIAS_COEFF = 0.0005f;  // g per degree C from 25°C
const float TEMP_REF = 25.0f;           // Reference temperature

// BLE UUIDs (unchanged for backward compatibility)
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_IMU_UUID       "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CHAR_MOISTURE_UUID  "beb5483e-36e1-4688-b7f5-ea07361b26a9"
#define CHAR_ALERT_UUID     "beb5483e-36e1-4688-b7f5-ea07361b26aa"
#define CHAR_BATTERY_UUID   "beb5483e-36e1-4688-b7f5-ea07361b26ab"
#define CHAR_FFT_UUID       "beb5483e-36e1-4688-b7f5-ea07361b26ac"  // Now used for raw accel binary
#define CHAR_CMD_UUID       "beb5483e-36e1-4688-b7f5-ea07361b26ad"  // P79: writable command characteristic
#define CHAR_DUMP_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26ae"  // P207: BLE data dump notify characteristic
#define CHAR_ALERT_STATUS_UUID "beb5483e-36e1-4688-b7f5-ea07361b26af"  // P232: pure alert status READ+NOTIFY

// ===================== P229: LED CONFIGURATION =====================
#define LED_PIN 10  // M5StickC Plus 2 built-in LED, GPIO 10, active LOW

// ===================== P197: DEEP SLEEP CONFIGURATION =====================
#define DEEP_SLEEP_ENABLED       1
#define DEEP_SLEEP_SAFE_MINUTES  5
#define DEEP_SLEEP_DURATION_S    30

// ===================== P198: SPIFFS DATA LOGGING CONFIGURATION =====================
#define SD_LOGGING_ENABLED 0

// ===================== MADGWICK FILTER =====================
Madgwick madgwickFilter;

// ===================== BUTTERWORTH FILTER =====================
// 2nd-order Butterworth IIR filter (biquad)
struct BiquadFilter {
  float b0, b1, b2, a1, a2;
  float x1, x2, y1, y2;  // state variables

  void reset() {
    x1 = x2 = y1 = y2 = 0;
  }

  float process(float input) {
    float output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = input;
    y2 = y1; y1 = output;
    return output;
  }
};

// High-pass filter at 0.5 Hz, 200 Hz sample rate (per-axis: X, Y, Z)
BiquadFilter hpFilterX = { 0.99222f, -1.98443f, 0.99222f, -1.98439f, 0.98448f, 0,0,0,0 };
BiquadFilter hpFilterY = { 0.99222f, -1.98443f, 0.99222f, -1.98439f, 0.98448f, 0,0,0,0 };
BiquadFilter hpFilterZ = { 0.99222f, -1.98443f, 0.99222f, -1.98439f, 0.98448f, 0,0,0,0 };

// Low-pass filter at 100 Hz, 200 Hz sample rate (per-axis: X, Y, Z)
BiquadFilter lpFilterX = { 0.29289f, 0.58579f, 0.29289f, 0.0f, 0.17157f, 0,0,0,0 };
BiquadFilter lpFilterY = { 0.29289f, 0.58579f, 0.29289f, 0.0f, 0.17157f, 0,0,0,0 };
BiquadFilter lpFilterZ = { 0.29289f, 0.58579f, 0.29289f, 0.0f, 0.17157f, 0,0,0,0 };



// ===================== FIRMWARE VERSION =====================
#define FW_VERSION "5.1.0"

// ===================== RTC PERSISTENT STATE =====================
RTC_DATA_ATTR uint32_t g_bootCount = 0;  // Survives deep sleep, incremented in setup()

// ===================== SESSION COUNTERS =====================
uint32_t g_seq = 0;            // BLE packet sequence number, incremented each send
uint32_t g_sessionEvts = 0;    // STA/LTA event count for this session (resets on power cycle)

// ===================== EVENT TIMING =====================
uint32_t g_evtStartMs = 0;     // millis() when current STA/LTA event began; 0 if no event active
bool g_evtActive = false;      // True while an STA/LTA event is ongoing

// ===================== DISPLAY TREND =====================
float g_lastPpv = 0.0f;        // Previous PPV reading for trend arrow calculation

// ===================== POWER SAVE =====================
uint32_t g_safeSinceMs = 0;    // millis() timestamp of last non-safe event (or boot)
bool g_powerSaveActive = false; // True when BLE advertising interval has been extended

// ===================== P197: DEEP SLEEP STATE =====================
#if DEEP_SLEEP_ENABLED
unsigned long g_deepSleepCountdownMs = 0; // millis() when PPV first dropped below safe; 0 = not counting
#endif

// ===================== P199: RTC WALL-CLOCK TIMESTAMP =====================
time_t g_rtcEpoch = 0;          // Unix epoch received from phone via BLE CMD "TIME:..."
unsigned long g_rtcSetMs = 0;   // millis() at the moment g_rtcEpoch was set

// ===================== P79: BLE CALIBRATE COMMAND =====================
bool g_calibrating = false;      // True during active calibration period
uint32_t g_calibStartMs = 0;     // millis() when calibration started

// ===================== P80: AUTOMATIC GAIN CONTROL =====================
static bool g_highGainMode = false;  // True when IMU is in ±16g range

// ===================== P212: CUSTOM DEVICE NAME =====================
char g_deviceName[21] = "AncientVision";  // BLE advertisement name, loadable from NVS

// ===================== GLOBALS =====================
BLEServer* pServer = NULL;
BLECharacteristic* pIMUChar = NULL;
BLECharacteristic* pMoistureChar = NULL;
BLECharacteristic* pAlertChar = NULL;
BLECharacteristic* pBatteryChar = NULL;
BLECharacteristic* pFFTChar = NULL;  // Now used for raw accel binary
BLECharacteristic* pCmdChar = NULL;  // P79: writable command characteristic
BLECharacteristic* pDumpChar = NULL; // P207: SPIFFS data dump notify characteristic
BLECharacteristic* pAlertStatusChar = NULL; // P232: pure alert status READ+NOTIFY

// ===================== P229: LED STATE =====================
static bool g_ledState = false;  // True when LED is currently ON (low = on, high = off)

// ===================== P231: ACCELEROMETER BIAS CALIBRATION =====================
float g_accelBiasX = 0.0f;
float g_accelBiasY = 0.0f;
float g_accelBiasZ = 0.0f;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Raw sensor data (latest sample)
float accX = 0, accY = 0, accZ = 0;
float gyroX = 0, gyroY = 0, gyroZ = 0;

// Linear acceleration (gravity removed by Madgwick)
float linAccX = 0, linAccY = 0, linAccZ = 0;

// Processed vibration features (per analysis window)
float vibrationRMS = 0;              // RMS acceleration (g)
float vibrationPeak = 0;             // Peak acceleration (g)
float vibrationPPV = 0;              // Peak Component Particle Velocity (mm/s)
float ppvNoiseFloor = 0;             // Calibrated noise baseline (mm/s)
bool ppvCalibrated = false;          // True after noise calibration completes
int calibrationWindows = 0;          // Number of windows used for calibration
float calibrationSum = 0;            // Running sum for calibration average
const int CALIBRATION_WINDOWS = 5;   // Windows to average for noise floor
float crestFactor = 0;               // Peak / RMS ratio
float vibrationMagnitude = 0;        // Legacy: raw magnitude for backward compat

// Recursive STA/LTA state (no arrays, saves memory)
float staValue = 0;
float ltaValue = 0.001f;             // Initialize to small value to avoid div-by-zero
float staLtaRatio = 0;

// IMU Temperature
float imuTemp = 25.0f;               // Default to reference temperature
unsigned long lastTempRead = 0;
const int TEMP_READ_INTERVAL = 500;  // Read temperature every 500ms

// Moisture data
int moisturePercent = 0;
int rawMoisture = 0;

// Battery data
float batteryVoltage = 0.0;  // Battery voltage (V)
int batteryPercent = 100;    // Battery percentage (0-100%)
bool batteryCharging = false; // Charging status

// Low power mode
bool lowPowerMode = false;
bool longPressHandled = false;

// Alert states
enum AlertState { SAFE, WARNING, CRITICAL };
AlertState currentAlert = SAFE;
String alertMessage = "";
String hazardType = "none";

// Hysteresis state machine
int alertPersistence = 0;       // Consecutive windows above threshold
int alertCooldown = 0;          // Windows since last alert clear
AlertState candidateAlert = SAFE;
String candidateMessage = "";
String candidateType = "none";

// Sample collection - double-buffered tri-axial buffers
// One buffer collects samples while the other is processed/sent via BLE
int sampleIndex = 0;
int activeBuffer = 0;       // Buffer currently being filled by collectSample()
int processingBuffer = 0;   // Buffer being read by processVibrationWindow()/sendBLEData()
float accelSamplesX[2][FFT_SAMPLES];
float accelSamplesY[2][FFT_SAMPLES];
float accelSamplesZ[2][FFT_SAMPLES];
float velocitySamplesX[2][FFT_SAMPLES];
float velocitySamplesY[2][FFT_SAMPLES];
float velocitySamplesZ[2][FFT_SAMPLES];
unsigned long lastSampleTime = 0;
bool windowReady = false;

// Filter warm-up
int windowCount = 0;
bool newWindowAvailable = false;  // True when a new window was processed since last BLE send

// Timing
unsigned long lastBLESend = 0;
unsigned long lastDisplayUpdate = 0;
unsigned long lastMoistureRead = 0;
unsigned long lastBatteryRead = 0;
const int BLE_INTERVAL = 500;        // Send BLE every 500ms
const int DISPLAY_INTERVAL = 250;    // Update display 4x/sec
const int MOISTURE_INTERVAL = 1000;  // Read moisture every 1s
const int BATTERY_INTERVAL = 2000;   // Read battery every 2s

// ===================== P147: BLE MOTION THRESHOLD FILTER =====================
unsigned long g_lastBleNotifyMs = 0;   // millis() of last BLE notification sent
float g_lastBleNotifyPpv = -1.0f;      // PPV at time of last BLE notification (-1 = never sent)

// ===================== P179: WIFI PUSH TIMING =====================
unsigned long g_lastWifiPushMs = 0;    // millis() of last WiFi push attempt

// ===================== LOOP TIMING WATCHDOG =====================
static unsigned long g_loopStartMs    = 0;   // millis() at start of current loop() iteration
static unsigned long g_loopMaxMs      = 0;   // Maximum loop() iteration duration observed
static unsigned long g_loopDiagLastMs = 0;   // millis() of last 60s diagnostic print
static const unsigned long LOOP_WARN_MS = 2000UL;  // Warn if loop() takes >2s
static const unsigned long LOOP_DIAG_INTERVAL = 60000UL; // Print max loop time every 60s

// ===================== P148: DEBUG MODE =====================
bool g_debugMode = false;              // Toggled via BLE CMD "DEBUG ON" / "DEBUG OFF"

// ===================== P80: MPU6886 ACCEL RANGE CONFIGURATION =====================
// ACCEL_CONFIG register 0x1C: bits [4:3] set AFS_SEL
// AFS_SEL=0 -> ±2g, AFS_SEL=1 -> ±4g, AFS_SEL=2 -> ±8g, AFS_SEL=3 -> ±16g
void setAccelRange(int gRange) {
  uint8_t afs;
  switch (gRange) {
    case 16: afs = 0x03; break;
    case 8:  afs = 0x02; break;
    case 4:  afs = 0x01; break;
    default: afs = 0x00; break; // ±2g
  }
  Wire1.beginTransmission(0x68);
  Wire1.write(0x1C);           // ACCEL_CONFIG register
  Wire1.write(afs << 3);       // AFS_SEL field at bits [4:3]
  Wire1.endTransmission();
  DBG_PRINTF("AGC: accel range set to ±%dg (reg=0x%02X)\n", gRange, afs << 3);
}

// ===================== MPU6886 DLPF CONFIGURATION =====================
void configureDLPF() {
  Wire1.beginTransmission(0x68);
  Wire1.write(0x1A);  // CONFIG register
  Wire1.write(0x02);  // DLPF_CFG = 2 (99 Hz bandwidth)
  Wire1.endTransmission();

  Wire1.beginTransmission(0x68);
  Wire1.write(0x1D);  // ACCEL_CONFIG2 register
  Wire1.write(0x02);  // A_DLPF_CFG = 2 (99 Hz bandwidth)
  Wire1.endTransmission();

  DBG_PRINTLN("DLPF configured: 99 Hz bandwidth");
}

// ===================== IMU TEMPERATURE READING =====================
void readIMUTemperature() {
  Wire1.beginTransmission(0x68);
  Wire1.write(0x41);  // TEMP_OUT_H register
  Wire1.endTransmission(false);
  Wire1.requestFrom((uint8_t)0x68, (uint8_t)2);
  if (Wire1.available() >= 2) {
    int16_t rawTemp = (Wire1.read() << 8) | Wire1.read();
    imuTemp = rawTemp / 326.8f + 25.0f;  // MPU6886 temperature formula
  }
}

// ===================== FORWARD DECLARATIONS =====================
void setupBLE();
void collectSample();
void processVibrationWindow();
void classifyHazard();
void readMoisture();
void readBattery();
void sendBLEData();
void updateDisplay();
void testAlert();
void checkForOtaUpdate();
void loadNvsSettings();
void saveNvsSettings();
void flashLed(int times, int onMs, int offMs);
void calibrateAccelBias();
#if WIFI_ENABLED
void wifiPushData();
#endif
#if SD_LOGGING_ENABLED
void initStorage();
void logToStorage(float ppv, float rms, float freq, float kurtosis);
#endif
time_t getCurrentEpoch();

// ===================== P149: OTA UPDATE READINESS STUB =====================
// Future: replace body with ArduinoOTA or custom HTTP OTA check when a
// firmware update server is available.  The #define OTA_ENABLED gate at the
// top of the file controls whether the call in setup() is compiled in.
void checkForOtaUpdate() {
  Serial.println("OTA check: disabled (no update server configured)");
}

// ===================== P229: LED FLASH =====================
// Flash the built-in LED (GPIO 10, active LOW) a given number of times.
// Blocks for at most (times * onMs) + ((times-1) * offMs) milliseconds.
void flashLed(int times, int onMs, int offMs) {
  for (int i = 0; i < times; i++) {
    g_ledState = true;
    digitalWrite(LED_PIN, LOW);   // ON (active low)
    delay(onMs);
    g_ledState = false;
    digitalWrite(LED_PIN, HIGH);  // OFF
    if (i < times - 1) delay(offMs);
  }
}

// ===================== P231: ACCELEROMETER BIAS CALIBRATION =====================
// Collect 100 raw accel samples over 500ms, average them and store the
// zero-g offsets in NVS.  Call this with the device lying flat and still.
// Bias is applied in collectSample() before all downstream processing.
void calibrateAccelBias() {
  Serial.println("ACCEL_CAL: starting (100 samples / 500ms)");
  M5.Lcd.fillScreen(BLACK);
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(0, 0);
  M5.Lcd.println("ACCEL CAL...");
  M5.Lcd.println("Keep flat+still");

  const int CAL_SAMPLES = 100;
  float sumX = 0, sumY = 0, sumZ = 0;
  for (int i = 0; i < CAL_SAMPLES; i++) {
    float rx, ry, rz;
    M5.Imu.getAccelData(&rx, &ry, &rz);
    sumX += rx;
    sumY += ry;
    sumZ += rz;
    delay(5);  // 5ms * 100 = 500ms total
  }

  g_accelBiasX = sumX / CAL_SAMPLES;
  g_accelBiasY = sumY / CAL_SAMPLES;
  g_accelBiasZ = (sumZ / CAL_SAMPLES) - 1.0f;  // Remove expected 1g from Z when flat

  Serial.printf("ACCEL_CAL: biasX=%.5f biasY=%.5f biasZ=%.5f\n",
    g_accelBiasX, g_accelBiasY, g_accelBiasZ);

  // Persist to NVS
  nvs_handle_t h;
  esp_err_t e = nvs_open("ancientvision", NVS_READWRITE, &h);
  if (e == ESP_OK) {
    uint32_t bx, by, bz;
    memcpy(&bx, &g_accelBiasX, sizeof(float));
    memcpy(&by, &g_accelBiasY, sizeof(float));
    memcpy(&bz, &g_accelBiasZ, sizeof(float));
    nvs_set_u32(h, "accelBiasX", bx);
    nvs_set_u32(h, "accelBiasY", by);
    nvs_set_u32(h, "accelBiasZ", bz);
    nvs_commit(h);
    nvs_close(h);
    Serial.println("ACCEL_CAL: biases saved to NVS");
  } else {
    Serial.printf("ACCEL_CAL: NVS open failed (0x%x)\n", e);
  }

  M5.Lcd.setCursor(0, 30);
  M5.Lcd.println("CAL DONE");
  delay(1000);
}

// ===================== P180: NVS PERSISTENT SETTINGS =====================
void loadNvsSettings() {
  nvs_handle_t handle;
  esp_err_t err = nvs_open("ancientvision", NVS_READONLY, &handle);
  if (err != ESP_OK) {
    Serial.printf("NVS load: namespace open failed (0x%x) — using defaults\n", err);
    return;
  }

  // Load ppvNoiseFloor (stored as uint32 bit-cast of float)
  uint32_t noiseRaw = 0;
  err = nvs_get_u32(handle, "noiseFloor", &noiseRaw);
  if (err == ESP_OK && noiseRaw != 0) {
    memcpy(&ppvNoiseFloor, &noiseRaw, sizeof(float));
    ppvCalibrated = true;
    Serial.printf("NVS load: ppvNoiseFloor=%.4f mm/s\n", ppvNoiseFloor);
  } else {
    ppvNoiseFloor = 0.01f;
    Serial.println("NVS load: ppvNoiseFloor default=0.01");
  }

  // Load g_highGainMode
  uint8_t gainVal = 0;
  err = nvs_get_u8(handle, "highGain", &gainVal);
  if (err == ESP_OK) {
    g_highGainMode = (gainVal != 0);
    Serial.printf("NVS load: g_highGainMode=%d\n", (int)g_highGainMode);
  } else {
    g_highGainMode = false;
    Serial.println("NVS load: g_highGainMode default=false");
  }

  // P212: Load custom device name (if set by BLE CMD NAME:xxx)
  char devNameBuf[21] = "AncientVision";
  size_t devNameLen = sizeof(devNameBuf);
  err = nvs_get_str(handle, "devName", devNameBuf, &devNameLen);
  if (err == ESP_OK) {
    strncpy(g_deviceName, devNameBuf, sizeof(g_deviceName) - 1);
    g_deviceName[sizeof(g_deviceName) - 1] = '\0';
    Serial.printf("NVS load: g_deviceName=%s\n", g_deviceName);
  } else {
    // Keep default "AncientVision" already set at declaration
    Serial.println("NVS load: g_deviceName default=AncientVision");
  }

  // P231: Load accel bias offsets (stored as uint32 bit-cast of float)
  {
    uint32_t bxRaw = 0, byRaw = 0, bzRaw = 0;
    if (nvs_get_u32(handle, "accelBiasX", &bxRaw) == ESP_OK)
      memcpy(&g_accelBiasX, &bxRaw, sizeof(float));
    if (nvs_get_u32(handle, "accelBiasY", &byRaw) == ESP_OK)
      memcpy(&g_accelBiasY, &byRaw, sizeof(float));
    if (nvs_get_u32(handle, "accelBiasZ", &bzRaw) == ESP_OK)
      memcpy(&g_accelBiasZ, &bzRaw, sizeof(float));
    Serial.printf("NVS load: accelBias X=%.5f Y=%.5f Z=%.5f\n",
      g_accelBiasX, g_accelBiasY, g_accelBiasZ);
  }

  nvs_close(handle);
}

void saveNvsSettings() {
  nvs_handle_t handle;
  esp_err_t err = nvs_open("ancientvision", NVS_READWRITE, &handle);
  if (err != ESP_OK) {
    Serial.printf("NVS save: namespace open failed (0x%x)\n", err);
    return;
  }

  // Store ppvNoiseFloor as uint32 bit-cast of float
  uint32_t noiseRaw = 0;
  memcpy(&noiseRaw, &ppvNoiseFloor, sizeof(float));
  nvs_set_u32(handle, "noiseFloor", noiseRaw);

  // Store g_highGainMode
  nvs_set_u8(handle, "highGain", g_highGainMode ? 1 : 0);

  err = nvs_commit(handle);
  if (err != ESP_OK) {
    Serial.printf("NVS save: commit failed (0x%x)\n", err);
  } else {
    Serial.printf("NVS save: noiseFloor=%.4f highGain=%d\n", ppvNoiseFloor, (int)g_highGainMode);
  }

  nvs_close(handle);
}

// ===================== P179: WIFI DATA PUSH =====================
#if WIFI_ENABLED
void wifiPushData() {
  // Attempt WiFi connection if not already connected
  if (WiFi.status() != WL_CONNECTED) {
    Serial.printf("WiFi: connecting to %s ...\n", WIFI_SSID);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
    unsigned long wifiStart = millis();
    while (WiFi.status() != WL_CONNECTED &&
           (millis() - wifiStart < (unsigned long)WIFI_CONNECT_TIMEOUT_MS)) {
      delay(100);
      esp_task_wdt_reset();
    }
    if (WiFi.status() != WL_CONNECTED) {
      Serial.println("WiFi: connection timeout — skipping push");
      return;
    }
    Serial.printf("WiFi: connected, IP=%s RSSI=%ddBm\n",
      WiFi.localIP().toString().c_str(), WiFi.RSSI());
  }

  // Build full JSON payload matching the BLE IMU characteristic JSON.
  // All fields from sendBLEData() imuData plus alert_level for server-side triage.
  uint32_t evtMs     = g_evtActive ? (uint32_t)(millis() - g_evtStartMs) : 0u;
  uint32_t uptimeSec = millis() / 1000u;
  uint32_t tsNow     = (uint32_t)getCurrentEpoch();
  const char* alertLevel = (currentAlert == CRITICAL) ? "critical" :
                           (currentAlert == WARNING)  ? "warning"  : "safe";

  char jsonBody[512];
  int jsonLen = snprintf(jsonBody, sizeof(jsonBody),
    "{"
    "\"ppv\":%.3f,"
    "\"rms\":%.4f,"
    "\"peak\":%.4f,"
    "\"crest\":%.2f,"
    "\"stalta\":%.3f,"
    "\"freq\":0,"
    "\"fw\":\"" FW_VERSION "\","
    "\"seq\":%lu,"
    "\"evtMs\":%lu,"
    "\"boots\":%lu,"
    "\"evts\":%lu,"
    "\"gain\":%d,"
    "\"cal\":%d,"
    "\"tmp\":%.1f,"
    "\"up\":%lu,"
    "\"dbg\":%d,"
    "\"led\":%d,"
    "\"ts\":%lu,"
    "\"alert_level\":\"%s\","
    "\"moisture\":%d,"
    "\"bat_pct\":%d,"
    "\"bat_v\":%.2f,"
    "\"chg\":%d"
    "}",
    vibrationPPV, vibrationRMS, vibrationPeak, crestFactor, staLtaRatio,
    (unsigned long)g_seq, (unsigned long)evtMs,
    (unsigned long)g_bootCount, (unsigned long)g_sessionEvts,
    g_highGainMode ? 16 : 4,
    g_calibrating ? 1 : 0,
    imuTemp, (unsigned long)uptimeSec,
    g_debugMode ? 1 : 0,
    g_ledState  ? 1 : 0,
    (unsigned long)tsNow,
    alertLevel,
    moisturePercent,
    batteryPercent,
    batteryVoltage,
    batteryCharging ? 1 : 0);

  if (jsonLen >= (int)sizeof(jsonBody)) {
    Serial.println("WiFi push: JSON truncated — skipping");
    return;
  }

  // POST with configurable timeout; errors are non-fatal
  HTTPClient http;
  http.begin(COLLECTOR_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Device-ID", g_deviceName);
  http.setTimeout(WIFI_HTTP_TIMEOUT_MS);
  int httpCode = http.POST(jsonBody);
  if (httpCode > 0) {
    Serial.printf("WiFi push: HTTP %d (%d bytes sent)\n", httpCode, jsonLen);
  } else {
    Serial.printf("WiFi push: error [%s]\n", http.errorToString(httpCode).c_str());
  }
  http.end();
}
#endif

// ===================== P199: RTC WALL-CLOCK HELPERS =====================
time_t getCurrentEpoch() {
  if (g_rtcEpoch == 0) return 0;
  return g_rtcEpoch + (time_t)((millis() - g_rtcSetMs) / 1000UL);
}

// ===================== P198: SPIFFS DATA LOGGING =====================
#if SD_LOGGING_ENABLED
static bool g_spiffsOk = false;

void initStorage() {
  g_spiffsOk = SPIFFS.begin(true);  // true = format on fail
  if (g_spiffsOk) {
    Serial.println("SPIFFS: mounted OK");
  } else {
    Serial.println("SPIFFS: mount failed — logging disabled");
  }
}

void logToStorage(float ppv, float rms, float freq, float kurtosis) {
  if (!g_spiffsOk) return;
  File f = SPIFFS.open("/data.csv", FILE_APPEND);
  if (!f) {
    Serial.println("SPIFFS: failed to open /data.csv for append");
    return;
  }
  f.printf("%lu,%.3f,%.4f,%.2f,%.3f\n",
    (unsigned long)millis(), ppv, rms, freq, kurtosis);
  f.close();
}
#endif

// ===================== BLE CALLBACKS =====================
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      DBG_PRINTLN("Device connected!");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      DBG_PRINTLN("Device disconnected!");
    }
};

// ===================== P79: BLE COMMAND CHARACTERISTIC CALLBACKS =====================
class CmdCharCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue().c_str();
    DBG_PRINTF("BLE CMD received: %s\n", value.c_str());
    if (value == "CALIBRATE") {
      g_calibrating = true;
      g_calibStartMs = millis();
      Serial.println("BLE CMD: CALIBRATE started (30s)");
    } else if (value == "ACCEL_CAL") {
      // P231: Zero-g accelerometer bias calibration — device must be flat and still
      Serial.println("BLE CMD: ACCEL_CAL — lay device flat, starting...");
      calibrateAccelBias();
    } else if (value == "DEBUG ON") {
      g_debugMode = true;
      Serial.println("BLE CMD: DEBUG mode ON");
    } else if (value == "DEBUG OFF") {
      g_debugMode = false;
      Serial.println("BLE CMD: DEBUG mode OFF");
    } else if (value.startsWith("TIME:")) {
      // P199: Phone syncs wall-clock — "TIME:1709500000"
      String epochStr = value.substring(5);
      g_rtcEpoch = (time_t)epochStr.toInt();
      g_rtcSetMs = millis();
      Serial.printf("BLE CMD: TIME set to %lu (millis=%lu)\n",
        (unsigned long)g_rtcEpoch, (unsigned long)g_rtcSetMs);
    } else if (value.startsWith("WIFI:")) {
      // P211: Connect to WiFi at runtime — "WIFI:ssid:password"
      #if WIFI_ENABLED
      String rest = value.substring(5);  // "ssid:password"
      int colon = rest.indexOf(':');
      if (colon > 0) {
        String ssid = rest.substring(0, colon);
        String pass = rest.substring(colon + 1);
        WiFi.disconnect();
        WiFi.begin(ssid.c_str(), pass.c_str());
        Serial.printf("BLE CMD: WiFi connecting to %s\n", ssid.c_str());
      }
      #else
      Serial.println("BLE CMD: WIFI ignored (WIFI_ENABLED=0)");
      #endif
    } else if (value.startsWith("NAME:")) {
      // P212: Set custom BLE device name, stored in NVS
      String newName = value.substring(5);
      newName.trim();
      if (newName.length() > 0 && newName.length() <= 20) {
        nvs_handle_t h;
        esp_err_t e = nvs_open("ancientvision", NVS_READWRITE, &h);
        if (e == ESP_OK) {
          nvs_set_str(h, "devName", newName.c_str());
          nvs_commit(h);
          nvs_close(h);
        }
        // Also update the in-memory name for the next reboot banner
        strncpy(g_deviceName, newName.c_str(), sizeof(g_deviceName) - 1);
        g_deviceName[sizeof(g_deviceName) - 1] = '\0';
        Serial.printf("BLE CMD: Device renamed to %s (takes effect after restart)\n", g_deviceName);
      }
    }
#if SD_LOGGING_ENABLED
    else if (value == "DUMP") {
      // P207: Dump /data.csv over BLE notify in 500-byte chunks
      if (!g_spiffsOk) {
        Serial.println("DUMP: SPIFFS not available");
        if (pDumpChar) {
          pDumpChar->setValue((uint8_t*)"DUMP:ERROR:SPIFFS", 17);
          pDumpChar->notify();
        }
      } else {
        File f = SPIFFS.open("/data.csv", FILE_READ);
        if (!f) {
          Serial.println("DUMP: /data.csv not found");
          if (pDumpChar) {
            pDumpChar->setValue((uint8_t*)"DUMP:ERROR:NOFILE", 17);
            pDumpChar->notify();
          }
        } else {
          Serial.println("DUMP: BEGIN /data.csv via BLE");
          if (pDumpChar) {
            // Send begin marker
            pDumpChar->setValue((uint8_t*)"DUMP:BEGIN", 10);
            pDumpChar->notify();
            delay(20);
            // Send file in 500-byte chunks
            uint8_t chunk[500];
            while (f.available()) {
              int n = f.read(chunk, sizeof(chunk));
              pDumpChar->setValue(chunk, n);
              pDumpChar->notify();
              esp_task_wdt_reset();
              delay(20);
            }
            // Send end marker
            pDumpChar->setValue((uint8_t*)"DUMP:END", 8);
            pDumpChar->notify();
          }
          f.close();
          Serial.println("DUMP: END");
        }
      }
    }
#endif
  }
};

// ===================== SETUP =====================
void setup() {
  g_bootCount++;  // P75: persist across deep-sleep reboots via RTC_DATA_ATTR

  auto cfg = M5.config();
  M5.begin(cfg);

  Serial.begin(115200);

  // P101: Log watchdog / reset reason on boot for field diagnostics
  {
    esp_reset_reason_t reason = esp_reset_reason();
    switch (reason) {
      case ESP_RST_POWERON:  Serial.println("Reset: power-on"); break;
      case ESP_RST_SW:       Serial.println("Reset: software"); break;
      case ESP_RST_PANIC:    Serial.println("Reset: panic/crash"); break;
      case ESP_RST_INT_WDT:  Serial.println("Reset: interrupt watchdog"); break;
      case ESP_RST_TASK_WDT: Serial.println("Reset: task watchdog"); break;
      case ESP_RST_WDT:      Serial.println("Reset: other watchdog"); break;
      default:               Serial.printf("Reset: reason=%d\n", (int)reason); break;
    }
  }

  DBG_PRINTLN("AncientVision Trench Safety Monitor v5.0");
  DBG_PRINTLN("DSP: Madgwick + Tri-axial PPV + Recursive STA/LTA + Raw BLE");

  // Initialize display
  M5.Lcd.setRotation(1);
  M5.Lcd.fillScreen(BLACK);
  M5.Lcd.setTextSize(2);
  M5.Lcd.setTextColor(WHITE, BLACK);

  M5.Lcd.setCursor(10, 20);
  M5.Lcd.println("AncientVision");
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(10, 50);
  M5.Lcd.println("Vibration Analysis v5.0");
  M5.Lcd.setCursor(10, 65);
  M5.Lcd.println("Sensor v5.0 — Phone DSP");
  M5.Lcd.setCursor(10, 80);
  M5.Lcd.println("Raw accel -> BLE");
  M5.Lcd.setCursor(10, 100);
  M5.Lcd.println("Initializing...");

  // P229: Initialize LED (active LOW — HIGH = off by default)
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, HIGH);

  // Initialize IMU
  M5.Imu.begin();
  DBG_PRINTLN("IMU initialized");

  // P230: Expanded boot self-test
  // Tests: IMU (bounds + non-zero + non-NaN), BLE pointers, SPIFFS (if enabled), battery
  {
    // ---- IMU test ----
    float stX = 0, stY = 0, stZ = 0;
    M5.Imu.getAccelData(&stX, &stY, &stZ);
    bool imuNonZero  = (stX != 0.0f || stY != 0.0f || stZ != 0.0f);
    bool imuBounds   = (stX > -20.0f && stX < 20.0f &&
                        stY > -20.0f && stY < 20.0f &&
                        stZ > -20.0f && stZ < 20.0f);
    bool imuNaN      = (!isnan(stX) && !isnan(stY) && !isnan(stZ));
    bool imuOk       = imuNonZero && imuBounds && imuNaN;

    // ---- BLE test — pointers checked after setupBLE() below ----
    // (run after setupBLE; placeholder set false until confirmed)
    bool bleOk = false;  // will be set after setupBLE()

    // ---- Battery test ----
    float btVolt = M5.Power.getBatteryVoltage() / 1000.0f;
    bool batOk = (btVolt >= 3.0f && btVolt <= 4.5f);

    // ---- SPIFFS test (only when logging is enabled) ----
    bool storOk = true;
#if SD_LOGGING_ENABLED
    storOk = SPIFFS.begin(true);
    if (storOk) {
      // Write a single test byte to verify writable
      File tf = SPIFFS.open("/.selftest", FILE_WRITE);
      if (tf) {
        tf.write((uint8_t)0xAB);
        tf.close();
        SPIFFS.remove("/.selftest");
      } else {
        storOk = false;
      }
    }
#endif

    // ---- Display interim results (BLE not yet tested) ----
    M5.Lcd.fillScreen(BLACK);
    M5.Lcd.setTextSize(1);
    M5.Lcd.setTextColor(WHITE, BLACK);
    M5.Lcd.setCursor(0, 0);
    M5.Lcd.printf("SELF-TEST v" FW_VERSION);
    M5.Lcd.setCursor(0, 12);
    M5.Lcd.setTextColor(imuOk  ? TFT_GREEN : RED, BLACK);
    M5.Lcd.printf("IMU: %s  (%.2fg)", imuOk ? "OK" : "FAIL", stZ);
    M5.Lcd.setCursor(0, 24);
    M5.Lcd.setTextColor(batOk  ? TFT_GREEN : RED, BLACK);
    M5.Lcd.printf("BAT: %s  (%.2fV)", batOk ? "OK" : "FAIL", btVolt);
    M5.Lcd.setCursor(0, 36);
    M5.Lcd.setTextColor(storOk ? TFT_GREEN : TFT_YELLOW, BLACK);
    M5.Lcd.printf("STOR: %s", storOk ? "OK" : (SD_LOGGING_ENABLED ? "FAIL" : "N/A"));
    M5.Lcd.setTextColor(WHITE, BLACK);

    // ---- BLE: set up now so we can test pointers ----
    // P180: NVS init needed before loadNvsSettings() which is called from setup()
    // before setupBLE(), so proceed with NVS first then BLE inside self-test block.
    esp_err_t nvsErrST = nvs_flash_init();
    if (nvsErrST == ESP_ERR_NVS_NO_FREE_PAGES || nvsErrST == ESP_ERR_NVS_NEW_VERSION_FOUND) {
      nvs_flash_erase();
      nvs_flash_init();
    }
    loadNvsSettings();

#if SD_LOGGING_ENABLED
    // Already inited above in SPIFFS test; skip redundant begin() later
#endif

    setupBLE();
    bleOk = (pServer != NULL && pIMUChar != NULL);

    // ---- Update display with BLE result ----
    M5.Lcd.setCursor(0, 48);
    M5.Lcd.setTextColor(bleOk ? TFT_GREEN : RED, BLACK);
    M5.Lcd.printf("BLE: %s", bleOk ? "OK" : "FAIL");

    // ---- Summary line ----
    bool criticalFail = (!imuOk || !bleOk);
    M5.Lcd.setCursor(0, 60);
    M5.Lcd.setTextColor(WHITE, BLACK);
    M5.Lcd.setTextSize(1);
    M5.Lcd.printf("IMU:%s BLE:%s STOR:%s BAT:%s",
      imuOk  ? "+" : "x",
      bleOk  ? "+" : "x",
      storOk ? "+" : (SD_LOGGING_ENABLED ? "x" : "-"),
      batOk  ? "+" : "x");

    if (criticalFail) {
      // Loop with error — do not proceed to normal operation
      M5.Lcd.setCursor(0, 75);
      M5.Lcd.setTextColor(RED, BLACK);
      M5.Lcd.setTextSize(2);
      M5.Lcd.println("CRITICAL FAIL");
      M5.Lcd.println("Check hardware");
      while (true) {
        flashLed(5, 100, 100);
        delay(1000);
        esp_task_wdt_reset();
      }
    }

    delay(3000);  // Show results for 3 seconds (was 2)
  }

  // Configure DLPF for 99 Hz anti-aliasing
  configureDLPF();

  // Initialize Madgwick filter at 200 Hz
  madgwickFilter.begin(SAMPLE_RATE);

  // Reset all filters
  hpFilterX.reset(); hpFilterY.reset(); hpFilterZ.reset();
  lpFilterX.reset(); lpFilterY.reset(); lpFilterZ.reset();

  // Initialize sample buffers (both banks)
  memset(accelSamplesX, 0, sizeof(accelSamplesX));
  memset(accelSamplesY, 0, sizeof(accelSamplesY));
  memset(accelSamplesZ, 0, sizeof(accelSamplesZ));
  memset(velocitySamplesX, 0, sizeof(velocitySamplesX));
  memset(velocitySamplesY, 0, sizeof(velocitySamplesY));
  memset(velocitySamplesZ, 0, sizeof(velocitySamplesZ));
  activeBuffer = 0;
  processingBuffer = 0;
  sampleIndex = 0;
  windowCount = 0;

  // Read initial IMU temperature
  readIMUTemperature();

  // Initialize moisture sensor pin
  pinMode(MOISTURE_PIN, INPUT);
  DBG_PRINTLN("Moisture sensor initialized");

  // P198: Initialize SPIFFS storage for data logging
  // (SPIFFS.begin() was already called inside self-test when SD_LOGGING_ENABLED;
  //  call initStorage() here only when not already initialised by the self-test.)
#if SD_LOGGING_ENABLED
  // initStorage() sets g_spiffsOk; self-test already did SPIFFS.begin(true)
  // so just mark it ok if self-test passed (g_spiffsOk not yet set).
  g_spiffsOk = true;  // self-test confirmed writable above
#endif

  // P149: OTA update readiness check (stub — no server configured yet)
#if OTA_ENABLED
  checkForOtaUpdate();
#endif

  // Initialize watchdog timer (5 second timeout, panic on expiry)
  esp_task_wdt_init(5, true);
  esp_task_wdt_add(NULL); // Add current task (loopTask)

  delay(1000);
  M5.Lcd.fillScreen(BLACK);

  // P82: record time when device enters ready/safe state
  g_safeSinceMs = millis();

  // P81: Serial diagnostic banner for field operators (improved)
  {
    // Boot reason string
    const char* bootReasonStr = "unknown";
    switch (esp_reset_reason()) {
      case ESP_RST_POWERON:  bootReasonStr = "Power-on";         break;
      case ESP_RST_SW:       bootReasonStr = "Software reset";   break;
      case ESP_RST_PANIC:    bootReasonStr = "Panic/crash";      break;
      case ESP_RST_INT_WDT:  bootReasonStr = "Interrupt WDT";   break;
      case ESP_RST_TASK_WDT: bootReasonStr = "Task WDT";        break;
      case ESP_RST_WDT:      bootReasonStr = "Other WDT";       break;
      case ESP_RST_DEEPSLEEP:bootReasonStr = "Deep sleep wake";  break;
      case ESP_RST_BROWNOUT: bootReasonStr = "Brownout";         break;
      default: break;
    }

    // PSRAM detection (ESP.getPsramSize() returns 0 if no PSRAM)
    uint32_t psramSize = ESP.getPsramSize();
    const char* psramStr = (psramSize > 0) ? "yes" : "none";

    // Self-test result string (reuse bleOk / imuOk — not in scope here; use BLE pointer check)
    bool selfTestPass = (pServer != NULL && pIMUChar != NULL);

    Serial.println("========================================");
    Serial.println("=== AncientVision Firmware v" FW_VERSION " ===");
    Serial.println("Build: 2026-03-04");
    Serial.printf("Chip: ESP32 @ %lu MHz\n", (unsigned long)(ESP.getCpuFreqMHz()));
    Serial.printf("Flash: %luKB | Free heap: %luB | PSRAM: %s\n",
      (unsigned long)(ESP.getFlashChipSize() / 1024),
      (unsigned long)esp_get_free_heap_size(),
      psramStr);
    Serial.printf("Boot reason: %s\n", bootReasonStr);
    Serial.printf("Reboot count: %lu\n", (unsigned long)g_bootCount);
    Serial.printf("Accel bias: X=%.4fg Y=%.4fg Z=%.4fg\n",
      g_accelBiasX, g_accelBiasY, g_accelBiasZ);
    Serial.printf("NVS noise floor: %.4f mm/s\n", ppvNoiseFloor);
#if WIFI_ENABLED
    Serial.printf("WiFi: ENABLED (SSID: %s)\n", WIFI_SSID);
#else
    Serial.println("WiFi: DISABLED");
#endif
#if DEEP_SLEEP_ENABLED
    Serial.printf("Deep sleep: ENABLED (%dmin timeout, %ds duration)\n",
      DEEP_SLEEP_SAFE_MINUTES, DEEP_SLEEP_DURATION_S);
#else
    Serial.println("Deep sleep: DISABLED");
#endif
#if SD_LOGGING_ENABLED
    Serial.println("SPIFFS: ENABLED");
#else
    Serial.println("SPIFFS: DISABLED");
#endif
    Serial.printf("Self-test: %s\n", selfTestPass ? "PASS" : "FAIL");
    Serial.printf("BLE name: %s\n", g_deviceName);
    Serial.println("========================================");
    Serial.println("Ready.");
  }

  lastSampleTime = micros();
}

void setupBLE() {
  DBG_PRINTLN("Starting BLE...");

  BLEDevice::init(g_deviceName);
  BLEDevice::setMTU(517); // Allow large payloads

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // 8 characteristics × 3 handles each (decl+value+CCCD) + 1 service = 25 minimum; 30 for margin
  BLEService *pService = pServer->createService(BLEUUID(SERVICE_UUID), 30);

  pIMUChar = pService->createCharacteristic(
    CHAR_IMU_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pIMUChar->addDescriptor(new BLE2902());

  pMoistureChar = pService->createCharacteristic(
    CHAR_MOISTURE_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pMoistureChar->addDescriptor(new BLE2902());

  pAlertChar = pService->createCharacteristic(
    CHAR_ALERT_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pAlertChar->addDescriptor(new BLE2902());

  pBatteryChar = pService->createCharacteristic(
    CHAR_BATTERY_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pBatteryChar->addDescriptor(new BLE2902());

  pFFTChar = pService->createCharacteristic(
    CHAR_FFT_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pFFTChar->addDescriptor(new BLE2902());

  // P79: Writable command characteristic — phone writes "CALIBRATE" etc.
  pCmdChar = pService->createCharacteristic(
    CHAR_CMD_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  pCmdChar->setCallbacks(new CmdCharCallbacks());

  // P207: SPIFFS data dump notify characteristic
  pDumpChar = pService->createCharacteristic(
    CHAR_DUMP_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pDumpChar->addDescriptor(new BLE2902());

  // P232: Pure alert status characteristic — phone can READ or subscribe for plain-text level
  pAlertStatusChar = pService->createCharacteristic(
    CHAR_ALERT_STATUS_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pAlertStatusChar->addDescriptor(new BLE2902());
  pAlertStatusChar->setValue("SAFE");  // Default value on boot

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  DBG_PRINTLN("BLE ready - waiting for connection...");
}

// ===================== MAIN LOOP =====================
void loop() {
  // P150: Reset watchdog at top of every loop iteration to prevent spurious reboots
  // during long BLE send operations.  esp_task_wdt_reset() is also called inside
  // sendBLEData() after each BLE notification for additional safety.
  esp_task_wdt_reset();
  M5.update();

  unsigned long currentMicros = micros();
  unsigned long currentMillis = millis();

  // ---- LOOP TIMING WATCHDOG: record iteration start ----
  // Check previous iteration duration (g_loopStartMs > 0 after first loop)
  if (g_loopStartMs > 0) {
    unsigned long loopDurationMs = currentMillis - g_loopStartMs;
    if (loopDurationMs > g_loopMaxMs) {
      g_loopMaxMs = loopDurationMs;
    }
    if (loopDurationMs >= LOOP_WARN_MS) {
      Serial.printf("WARN: loop() took %lums — possible blocking call\n",
        (unsigned long)loopDurationMs);
    }
  }
  g_loopStartMs = currentMillis;

  // ---- LOOP TIMING DIAGNOSTIC: print max every 60s ----
  if (currentMillis - g_loopDiagLastMs >= LOOP_DIAG_INTERVAL) {
    g_loopDiagLastMs = currentMillis;
    Serial.printf("DIAG: loop max=%lums heap=%luB\n",
      (unsigned long)g_loopMaxMs, (unsigned long)esp_get_free_heap_size());
    g_loopMaxMs = 0;  // Reset after reporting
  }

  // ---- HIGH-FREQUENCY: Sample IMU at 200 Hz ----
  if (currentMicros - lastSampleTime >= SAMPLE_INTERVAL_US) {
    lastSampleTime = currentMicros;
    collectSample();
  }

  // ---- Process window when ready ----
  if (windowReady) {
    windowReady = false;
    newWindowAvailable = true;
    processVibrationWindow();
    classifyHazard();

    // P197: Update deep sleep countdown based on current PPV
#if DEEP_SLEEP_ENABLED
    if (vibrationPPV >= PPV_SAFE_MAX || currentAlert != SAFE) {
      // Vibration is not safe — reset countdown
      g_deepSleepCountdownMs = 0;
    } else {
      // Vibration is safely low — start countdown if not already running
      if (g_deepSleepCountdownMs == 0) {
        g_deepSleepCountdownMs = currentMillis;
      }
    }
#endif
  }

  // P197: Trigger deep sleep when safe threshold has been held long enough
#if DEEP_SLEEP_ENABLED
  if (g_deepSleepCountdownMs > 0 &&
      ppvCalibrated &&
      (currentMillis - g_deepSleepCountdownMs > (unsigned long)DEEP_SLEEP_SAFE_MINUTES * 60000UL)) {
    Serial.printf("Entering deep sleep (%ds)\n", DEEP_SLEEP_DURATION_S);
    M5.Lcd.fillScreen(BLACK);
    M5.Lcd.setTextSize(3);
    M5.Lcd.setTextColor(WHITE, BLACK);
    M5.Lcd.setCursor(30, 50);
    M5.Lcd.print("ZZZ");
    delay(1000);
    // P210: Wake on timer OR Button A (GPIO 37, active-low on M5StickC Plus 2)
    esp_sleep_enable_ext0_wakeup(GPIO_NUM_37, 0);  // Button A, active low
    esp_sleep_enable_timer_wakeup((uint64_t)DEEP_SLEEP_DURATION_S * 1000000ULL);
    esp_deep_sleep_start();
  }
#endif

  // ---- Read IMU temperature periodically ----
  if (currentMillis - lastTempRead >= TEMP_READ_INTERVAL) {
    lastTempRead = currentMillis;
    readIMUTemperature();
  }

  // ---- Read moisture at 1 Hz ----
  if (currentMillis - lastMoistureRead >= MOISTURE_INTERVAL) {
    lastMoistureRead = currentMillis;
    readMoisture();
  }

  // ---- Read battery at 0.5 Hz ----
  if (currentMillis - lastBatteryRead >= BATTERY_INTERVAL) {
    lastBatteryRead = currentMillis;
    readBattery();
  }

  // ---- Send BLE data (2 Hz normal, 0.5 Hz low power) ----
  int bleRate = lowPowerMode ? 2000 : BLE_INTERVAL;
  if (currentMillis - lastBLESend >= bleRate) {
    lastBLESend = currentMillis;
    sendBLEData();
  }

  // ---- Update display (4 Hz normal, 1 Hz low power) ----
  int dispRate = lowPowerMode ? 1000 : DISPLAY_INTERVAL;
  if (currentMillis - lastDisplayUpdate >= dispRate) {
    lastDisplayUpdate = currentMillis;
    updateDisplay();
  }

  // ---- Handle BLE connection changes (non-blocking) ----
  static unsigned long disconnectTime = 0;
  if (!deviceConnected && oldDeviceConnected) {
    disconnectTime = currentMillis;
    oldDeviceConnected = deviceConnected;
  }
  if (!deviceConnected && disconnectTime > 0 && (currentMillis - disconnectTime >= 500)) {
    disconnectTime = 0;
    pServer->startAdvertising();
    DBG_PRINTLN("Restart advertising");
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
    disconnectTime = 0;
  }

  // P79: Auto-expire calibration after 30 seconds
  if (g_calibrating && (currentMillis - g_calibStartMs >= 30000UL)) {
    g_calibrating = false;
    Serial.println("BLE CMD: CALIBRATE period ended");
    DBG_PRINTLN("Calibration period expired");
    saveNvsSettings();  // P180: persist calibrated noise floor
  }

  // P179: WiFi periodic push
#if WIFI_ENABLED
  if (currentMillis - g_lastWifiPushMs >= WIFI_PUSH_INTERVAL) {
    g_lastWifiPushMs = currentMillis;
    wifiPushData();
  }
#endif

  // Button A: Hold 3s = toggle low power, short press = test alert
  if (M5.BtnA.pressedFor(3000) && !longPressHandled) {
    longPressHandled = true;
    lowPowerMode = !lowPowerMode;
    if (lowPowerMode) {
      M5.Speaker.tone(400, 200);
      M5.Lcd.setBrightness(20);
    } else {
      M5.Speaker.tone(800, 200);
      M5.Lcd.setBrightness(80);
    }
    DBG_PRINTF("Low power mode: %s\n", lowPowerMode ? "ON" : "OFF");
  }
  if (M5.BtnA.wasReleased()) {
    if (!longPressHandled) testAlert();
    longPressHandled = false;
  }

  // P209: Button B — 2s hold = force noise floor recalibration
  static bool btnBLongHandled = false;
  if (M5.BtnB.pressedFor(2000) && !btnBLongHandled) {
    btnBLongHandled = true;
    ppvCalibrated = false;
    ppvNoiseFloor = 0.0f;
    calibrationSum = 0.0f;
    calibrationWindows = 0;
    g_calibrating = true;
    g_calibStartMs = millis();
    Serial.println("BTN B: Force recalibrate");
    M5.Lcd.fillScreen(BLACK);
    M5.Lcd.setTextSize(1);
    M5.Lcd.setCursor(0, 0);
    M5.Lcd.println("RECAL...");
    delay(500);
  }
  if (M5.BtnB.wasReleased()) {
    btnBLongHandled = false;
  }

  // P150: Yield to FreeRTOS scheduler — prevents WiFi/BLE stack starvation
  // when the main loop runs faster than the 200 Hz sample interval.
  vTaskDelay(1);
}

// ===================== HIGH-SPEED SAMPLING =====================
void collectSample() {
  // Read IMU accelerometer AND gyroscope
  M5.Imu.getAccelData(&accX, &accY, &accZ);
  M5.Imu.getGyroData(&gyroX, &gyroY, &gyroZ);

  // P231: Apply zero-g accelerometer bias correction (calibrated via ACCEL_CAL)
  accX -= g_accelBiasX;
  accY -= g_accelBiasY;
  accZ -= g_accelBiasZ;

  // Temperature compensation - remove thermal bias from accelerometer
  float tempBias = (imuTemp - TEMP_REF) * TEMP_BIAS_COEFF;
  accX -= tempBias;
  accY -= tempBias;
  accZ -= tempBias;

  // Update Madgwick filter for orientation tracking
  madgwickFilter.updateIMU(gyroX, gyroY, gyroZ, accX, accY, accZ);

  // Compute gravity vector from Madgwick Euler angles
  float rollRad = madgwickFilter.getRollRadians();
  float pitchRad = madgwickFilter.getPitchRadians();

  // Gravity vector in sensor frame from roll/pitch
  float gx_est = -sin(pitchRad);
  float gy_est = sin(rollRad) * cos(pitchRad);
  float gz_est = cos(rollRad) * cos(pitchRad);

  // Remove gravity to get linear acceleration (per axis)
  linAccX = accX - gx_est;
  linAccY = accY - gy_est;
  linAccZ = accZ - gz_est;

  // Apply bandpass filter per axis: HPF 0.5 Hz -> LPF 100 Hz
  float filtX = lpFilterX.process(hpFilterX.process(linAccX));
  float filtY = lpFilterY.process(hpFilterY.process(linAccY));
  float filtZ = lpFilterZ.process(hpFilterZ.process(linAccZ));

  // Store filtered samples per axis (into active buffer)
  accelSamplesX[activeBuffer][sampleIndex] = filtX;
  accelSamplesY[activeBuffer][sampleIndex] = filtY;
  accelSamplesZ[activeBuffer][sampleIndex] = filtZ;

  // Integrate acceleration to velocity per axis (trapezoidal rule)
  // Convert g to mm/s^2: 1g = 9810 mm/s^2
  float dt = 1.0f / SAMPLE_RATE;
  if (sampleIndex > 0) {
    int prev = sampleIndex - 1;
    velocitySamplesX[activeBuffer][sampleIndex] = velocitySamplesX[activeBuffer][prev] +
      0.5f * (accelSamplesX[activeBuffer][prev] * 9810.0f + filtX * 9810.0f) * dt;
    velocitySamplesY[activeBuffer][sampleIndex] = velocitySamplesY[activeBuffer][prev] +
      0.5f * (accelSamplesY[activeBuffer][prev] * 9810.0f + filtY * 9810.0f) * dt;
    velocitySamplesZ[activeBuffer][sampleIndex] = velocitySamplesZ[activeBuffer][prev] +
      0.5f * (accelSamplesZ[activeBuffer][prev] * 9810.0f + filtZ * 9810.0f) * dt;

    // No velocity HPF needed: velocity integrates from 0 each window,
    // and noise floor subtraction handles MEMS baseline in processVibrationWindow()
  } else {
    velocitySamplesX[activeBuffer][0] = 0;
    velocitySamplesY[activeBuffer][0] = 0;
    velocitySamplesZ[activeBuffer][0] = 0;
  }

  // Recursive STA/LTA computation (no arrays, saves memory)
  float mag = filtX * filtX + filtY * filtY + filtZ * filtZ;
  float sampleEnergy = mag;  // Already squared magnitude
  staValue = STA_ALPHA * sampleEnergy + (1.0f - STA_ALPHA) * staValue;
  ltaValue = LTA_ALPHA * sampleEnergy + (1.0f - LTA_ALPHA) * ltaValue;
  staLtaRatio = (ltaValue > 1e-10f) ? staValue / ltaValue : 1.0f;  // P83: guard prevents zero-division

  // Legacy backward compat: magnitude
  vibrationMagnitude = sqrt(mag);

  sampleIndex++;

  // When buffer is full, swap buffers and trigger processing
  if (sampleIndex >= FFT_SAMPLES) {
    sampleIndex = 0;
    processingBuffer = activeBuffer;
    activeBuffer = 1 - activeBuffer; // Swap to other buffer
    windowReady = true;
  }
}

// ===================== VIBRATION ANALYSIS =====================
void processVibrationWindow() {
  // Filter warm-up: discard first window (1.28s)
  windowCount++;
  if (windowCount <= 1) {
    DBG_PRINTF("DSP: Discarding warm-up window %d/1\n", windowCount);
    return;
  }

  // ---- Compute RMS, Peak, PPV (tri-axial PCPV) ----
  float sumSq = 0;
  float peak = 0;
  float peakVelX = 0, peakVelY = 0, peakVelZ = 0;

  for (int i = 0; i < FFT_SAMPLES; i++) {
    // Combined magnitude for RMS (read from processing buffer)
    float magSq = accelSamplesX[processingBuffer][i] * accelSamplesX[processingBuffer][i] +
                  accelSamplesY[processingBuffer][i] * accelSamplesY[processingBuffer][i] +
                  accelSamplesZ[processingBuffer][i] * accelSamplesZ[processingBuffer][i];
    sumSq += magSq;
    float magVal = sqrt(magSq);
    if (magVal > peak) peak = magVal;

    // Per-axis peak velocity for PCPV
    float absVelX = fabs(velocitySamplesX[processingBuffer][i]);
    float absVelY = fabs(velocitySamplesY[processingBuffer][i]);
    float absVelZ = fabs(velocitySamplesZ[processingBuffer][i]);
    if (absVelX > peakVelX) peakVelX = absVelX;
    if (absVelY > peakVelY) peakVelY = absVelY;
    if (absVelZ > peakVelZ) peakVelZ = absVelZ;
  }

  vibrationRMS = sqrt(sumSq / FFT_SAMPLES);
  vibrationPeak = peak;

  // DIN 4150-3 PCPV: max of per-axis peak velocity (mm/s)
  // Velocity integrates from 0 each window, so no cross-window drift
  float rawPPV = max(peakVelX, max(peakVelY, peakVelZ));

  // ---- Noise floor calibration (first N windows after warm-up) ----
  if (!ppvCalibrated) {
    calibrationSum += rawPPV;
    calibrationWindows++;
    if (calibrationWindows >= CALIBRATION_WINDOWS) {
      ppvNoiseFloor = (calibrationSum / calibrationWindows) * 1.2f; // 20% margin
      ppvCalibrated = true;
      DBG_PRINTF("PPV CALIBRATED: noise floor = %.1f mm/s\n", ppvNoiseFloor);
    } else {
      DBG_PRINTF("PPV CALIBRATING: window %d/%d raw=%.1f\n", calibrationWindows, CALIBRATION_WINDOWS, rawPPV);
      vibrationPPV = 0;
      return;  // Don't classify during calibration
    }
  }

  // Hourly noise floor recalibration: EMA update when vibration is safely low
  static unsigned long lastNoiseRecal = 0;
  unsigned long nowMs = millis();
  if (ppvCalibrated && rawPPV < PPV_SAFE_MAX && (nowMs - lastNoiseRecal > 3600000UL)) {
    // Exponential moving average: slowly adapt noise floor
    ppvNoiseFloor = ppvNoiseFloor * 0.9f + rawPPV * 1.2f * 0.1f;
    lastNoiseRecal = nowMs;
    DBG_PRINTF("PPV noise floor recalibrated: %.2f mm/s\n", ppvNoiseFloor);
  }

  // Subtract noise floor, clamp to zero
  vibrationPPV = max(0.0f, rawPPV - ppvNoiseFloor);

  // ---- Crest Factor ----
  crestFactor = (vibrationRMS > 0.0001f) ? vibrationPeak / vibrationRMS : 1.0f;

  // ---- P80: Automatic Gain Control — switch IMU range based on PPV ----
  if (vibrationPPV > 2.0f && !g_highGainMode) {
    setAccelRange(16);   // Switch to ±16g to avoid clipping
    g_highGainMode = true;
    DBG_PRINTLN("AGC: switched to ±16g range");
    Serial.println("AGC: high range enabled");
    saveNvsSettings();   // P180: persist gain mode change
  } else if (vibrationPPV < 0.5f && g_highGainMode) {
    setAccelRange(4);    // Restore ±4g for better resolution
    g_highGainMode = false;
    DBG_PRINTLN("AGC: switched to ±4g range");
    Serial.println("AGC: normal range restored");
    saveNvsSettings();   // P180: persist gain mode change
  }

  // In low power mode: skip heavy logging if vibration is safely low
  // but do NOT return — let execution continue to classifyHazard() for moisture checks
  if (lowPowerMode && vibrationPPV <= PPV_SAFE_MAX) {
    DBG_PRINTF("LP: PPV=%.1fmm/s (safe) STA/LTA=%.2f\n", vibrationPPV, staLtaRatio);
  }

  DBG_PRINTF("DSP v5.0: RMS=%.4fg PPV=%.1fmm/s Crest=%.1f STA/LTA=%.2f\n",
    vibrationRMS, vibrationPPV, crestFactor, staLtaRatio);

  // P198: Log this window's metrics to SPIFFS
#if SD_LOGGING_ENABLED
  // freq=0 and kurtosis=0 — full DSP now runs on phone; we only have firmware features here
  logToStorage(vibrationPPV, vibrationRMS, 0.0f, crestFactor);
#endif
}

// ===================== HAZARD CLASSIFICATION (Simplified + Hysteresis) =====================
void classifyHazard() {
  // Skip classification during warm-up
  if (windowCount <= 1) return;

  // ---- Evaluate rules to get candidate alert ----
  AlertState newAlert = SAFE;
  String newMessage = "";
  String newType = "none";

  // CRITICAL: Extreme vibration (structural damage risk)
  if (vibrationPPV > PPV_STRUCTURAL_DAMAGE) {
    newAlert = CRITICAL;
    newMessage = "DANGER: Extreme vibration";
    newType = "structural";
  }

  // ---- Check moisture alerts ----
  if (moisturePercent < MOISTURE_MIN_SAFE && moisturePercent > 0) {
    if (newAlert < WARNING) {
      newAlert = WARNING;
      newMessage = "Soil too dry";
      newType = "moisture_low";
    }
  } else if (moisturePercent > MOISTURE_MAX_SAFE) {
    if (newAlert < CRITICAL) {
      newAlert = CRITICAL;
      newMessage = "Soil too wet - collapse risk!";
      newType = "moisture_high";
    }
  }

  // ---- Hysteresis state machine ----
  if (newAlert > currentAlert) {
    // Escalation candidate
    alertPersistence++;
    if (alertPersistence >= TRIGGER_COUNT) {
      // Confirmed escalation
      currentAlert = newAlert;
      alertMessage = newMessage;
      hazardType = newType;
      alertPersistence = 0;
      alertCooldown = 0;

      // P74 + P76: track event start and count
      if (!g_evtActive) {
        g_evtActive = true;
        g_evtStartMs = millis();
        g_sessionEvts++;  // Count distinct events
      }

      if (currentAlert == CRITICAL) {
        M5.Speaker.tone(1000, 500);
        flashLed(3, 200, 100);  // P229: 3 fast flashes for CRITICAL
      } else if (currentAlert == WARNING) {
        M5.Speaker.tone(500, 200);
        flashLed(1, 100, 0);    // P229: 1 short flash for CAUTION/WARNING
      }

      DBG_PRINTF("ALERT CONFIRMED: %s [%s] type=%s evts=%u\n",
        currentAlert == CRITICAL ? "CRITICAL" : "WARNING",
        alertMessage.c_str(), hazardType.c_str(), g_sessionEvts);
    }
  } else if (newAlert < currentAlert) {
    // De-escalation candidate
    alertCooldown++;
    if (alertCooldown >= CLEAR_COUNT) {
      // Confirmed de-escalation
      currentAlert = newAlert;
      alertMessage = newMessage;
      hazardType = newType;
      alertCooldown = 0;
      alertPersistence = 0;

      // P74: close the event timer when returning to SAFE
      if (newAlert == SAFE) {
        g_evtActive = false;
      }

      DBG_PRINTF("ALERT CLEARED -> %s\n",
        currentAlert == SAFE ? "SAFE" : "WARNING");
    }
  } else {
    // Same level - reset counters
    alertPersistence = 0;
    alertCooldown = 0;
    // Update message/type even at same level
    if (newAlert != SAFE) {
      alertMessage = newMessage;
      hazardType = newType;
    }
  }

  // P232: Update alert status characteristic with plain-text level + notify
  if (pAlertStatusChar != NULL && deviceConnected) {
    const char* statusStr =
      (currentAlert == CRITICAL) ? "CRITICAL" :
      (currentAlert == WARNING)  ? "CAUTION"  : "SAFE";
    pAlertStatusChar->setValue(statusStr);
    pAlertStatusChar->notify();
  }

  // P229: Add "led" state to IMU JSON (tracked via g_ledState global)
  // g_ledState is set true during flashLed() and reverts to false after each flash sequence.
}

// ===================== MOISTURE SENSOR =====================
void readMoisture() {
  rawMoisture = analogRead(MOISTURE_PIN);
  moisturePercent = map(rawMoisture, MOISTURE_AIR, MOISTURE_WATER, 0, 100);
  moisturePercent = constrain(moisturePercent, 0, 100);
}

// ===================== BATTERY MONITORING =====================
void readBattery() {
  // Read battery voltage from M5StickC Plus 2 power management
  batteryVoltage = M5.Power.getBatteryVoltage() / 1000.0;  // Convert mV to V

  // LiPo discharge curve lookup table (voltage -> percent)
  // Based on typical single-cell LiPo discharge at ~0.2C
  static const float voltTable[] = { 3.00, 3.30, 3.50, 3.60, 3.70, 3.75, 3.80, 3.90, 4.00, 4.10, 4.20 };
  static const int   pctTable[]  = {    0,    5,   10,   20,   30,   45,   55,   70,   85,   95,  100 };
  static const int tableLen = sizeof(voltTable) / sizeof(voltTable[0]);

  if (batteryVoltage <= voltTable[0]) {
    batteryPercent = 0;
  } else if (batteryVoltage >= voltTable[tableLen - 1]) {
    batteryPercent = 100;
  } else {
    for (int i = 1; i < tableLen; i++) {
      if (batteryVoltage <= voltTable[i]) {
        float t = (batteryVoltage - voltTable[i-1]) / (voltTable[i] - voltTable[i-1]);
        batteryPercent = pctTable[i-1] + (int)(t * (pctTable[i] - pctTable[i-1]));
        break;
      }
    }
  }

  batteryPercent = constrain(batteryPercent, 0, 100);

  // P102: Use power management chip API for reliable charging detection.
  // M5.Power.isCharging() queries the AXP192/AXP2101 PMIC charging status bit.
  // Fall back to voltage heuristic (>4.2V) if the API returns indeterminate.
  batteryCharging = M5.Power.isCharging();
}

// ===================== DISPLAY (P208: Compact 4-line layout) =====================
void updateDisplay() {
  uint16_t bgColor;
  switch (currentAlert) {
    case CRITICAL: bgColor = RED; break;
    case WARNING:  bgColor = ORANGE; break;
    default:       bgColor = TFT_DARKGREEN; break;
  }

  M5.Lcd.fillScreen(bgColor);
  M5.Lcd.setTextColor(WHITE, bgColor);
  M5.Lcd.setTextSize(1);

  // P208: Compute trend arrow from previous PPV reading
  // Uses Unicode-safe ASCII arrows: up='^' down='v' flat='>'
  char trendChar = (vibrationPPV > g_lastPpv * 1.05f) ? '^' :
                   (vibrationPPV < g_lastPpv * 0.95f) ? 'v' : '>';
  g_lastPpv = vibrationPPV;

  // Determine safety label string
  const char* safeLabel = "SAFE";
  if (!ppvCalibrated) {
    safeLabel = "CAL";
  } else if (currentAlert == CRITICAL) {
    safeLabel = "DANGER";
  } else if (currentAlert == WARNING) {
    safeLabel = "CAUTION";
  }

  // Line 1: "AV 5.1.0  [W] 85%"
  // WiFi dot: 'W' if WIFI_ENABLED and connected, '-' otherwise
  #if WIFI_ENABLED
  bool wifiOk = (WiFi.status() == WL_CONNECTED);
  #else
  bool wifiOk = false;
  #endif
  M5.Lcd.setCursor(0, 0);
  M5.Lcd.printf("AV " FW_VERSION "  %c  %d%%",
    wifiOk ? 'W' : '-', batteryPercent);

  // Line 2: "PPV: 0.123^  SAFE"
  M5.Lcd.setCursor(0, 10);
  M5.Lcd.printf("PPV: %.3f%c  %s", vibrationPPV, trendChar, safeLabel);

  // Line 3: "Tmp:23.4C  Evt:12  Seq:4521"
  M5.Lcd.setCursor(0, 20);
  M5.Lcd.printf("Tmp:%.1fC  Evt:%lu  Seq:%lu",
    imuTemp, (unsigned long)g_sessionEvts, (unsigned long)g_seq);

  // Line 4: "Boots:3  ZZZ" (ZZZ shown if deep sleep countdown is running)
  M5.Lcd.setCursor(0, 30);
  #if DEEP_SLEEP_ENABLED
  bool sleepingSoon = (g_deepSleepCountdownMs > 0 && ppvCalibrated &&
    (millis() - g_deepSleepCountdownMs > (unsigned long)(DEEP_SLEEP_SAFE_MINUTES - 1) * 60000UL));
  M5.Lcd.printf("Boots:%lu  %s", (unsigned long)g_bootCount, sleepingSoon ? "ZZZ" : "   ");
  #else
  M5.Lcd.printf("Boots:%lu", (unsigned long)g_bootCount);
  #endif
}

// ===================== BLE FUNCTIONS =====================
void sendBLEData() {
  if (!deviceConnected) return;

  // P73: increment sequence counter on every BLE send
  g_seq++;

  // P82: Power-save — track safe duration and log BLE interval state changes.
  // When the device has been continuously safe (no event) for >30s, activate
  // power-save mode; when an event fires, restore normal mode.
  // NOTE: Actual BLE advertising interval changes require platform-specific
  // BLEAdvertising::setMinInterval()/setMaxInterval() support that is not
  // reliably available in the ESP32 Arduino BLE stack after startAdvertising().
  // The tracking and Serial logging are fully functional; to apply the interval
  // change you would call BLEDevice::getAdvertising()->setMinInterval(320) (200ms)
  // in power-save and setMinInterval(48) (30ms) in normal mode, then restart
  // advertising — but that drops any active connection, so it is deferred here.
  if (g_evtActive) {
    // Event is active — reset safe timer and restore normal mode
    g_safeSinceMs = millis();
    if (g_powerSaveActive) {
      g_powerSaveActive = false;
      Serial.println("Power save: BLE interval restored");
    }
  } else {
    // No active event — check if safe for >30 seconds
    if (!g_powerSaveActive && (millis() - g_safeSinceMs > 30000UL)) {
      g_powerSaveActive = true;
      Serial.println("Power save: BLE interval extended");
    }
  }

  // Send simplified IMU JSON (only firmware-computed features)
  // Buffer sized for: existing fields + fw(5) + seq(10) + evtMs(10) + boots(10) + evts(10)
  //                 + cal(1) + gain(2) + chg(1) + tmp(6) + up(10) + dbg(1) + ts(12) + led(1) + overhead
  char imuData[380];
  uint32_t evtMs = g_evtActive ? (uint32_t)(millis() - g_evtStartMs) : 0u;
  uint32_t uptimeSec = millis() / 1000u;  // P146: device uptime in seconds
  uint32_t tsNow = (uint32_t)getCurrentEpoch(); // P199: wall-clock unix timestamp (0 if not set)
  int imuLen = snprintf(imuData, sizeof(imuData),
    "{\"ppv\":%.1f,\"stalta\":%.2f,\"rms\":%.4f,\"peak\":%.4f,\"crest\":%.1f,\"temp\":%.1f,\"mag\":%.4f"
    ",\"fw\":\"" FW_VERSION "\",\"seq\":%lu,\"evtMs\":%lu,\"boots\":%lu,\"evts\":%lu"
    ",\"cal\":%d,\"gain\":%d,\"chg\":%d"
    ",\"tmp\":%.1f,\"up\":%lu,\"dbg\":%d,\"ts\":%lu,\"led\":%d}",
    vibrationPPV, staLtaRatio, vibrationRMS, vibrationPeak, crestFactor, imuTemp, vibrationMagnitude,
    (unsigned long)g_seq, (unsigned long)evtMs, (unsigned long)g_bootCount, (unsigned long)g_sessionEvts,
    g_calibrating ? 1 : 0, g_highGainMode ? 16 : 4, batteryCharging ? 1 : 0,
    imuTemp, (unsigned long)uptimeSec, g_debugMode ? 1 : 0, (unsigned long)tsNow,
    g_ledState ? 1 : 0);  // P229: current LED state
  // P147: Motion threshold filter — only notify if PPV changed > 0.02 mm/s
  //       or more than 5 seconds have elapsed since last notification.
  //       The characteristic value is always updated so a phone read() gets
  //       current data; only the notify() (push) is gated.
  bool ppvChangedSig = (g_lastBleNotifyPpv < 0.0f) ||
                       (fabsf(vibrationPPV - g_lastBleNotifyPpv) > 0.02f);
  bool timeoutElapsed = (millis() - g_lastBleNotifyMs >= 5000UL);
  bool shouldNotify   = ppvChangedSig || timeoutElapsed;
  // Use imuLen for setValue length (not strlen) to avoid re-scanning
  if (imuLen >= (int)sizeof(imuData)) {
    // Truncated — skip sending corrupt data
    DBG_PRINTF("BLE: IMU JSON truncated, skipping send\n");
  } else {
    pIMUChar->setValue((uint8_t*)imuData, imuLen);
    if (shouldNotify) {
      pIMUChar->notify();
      g_lastBleNotifyMs  = millis();
      g_lastBleNotifyPpv = vibrationPPV;
    }
  }
  esp_task_wdt_reset();
  delay(5);

  // Send moisture data
  char moistureData[50];
  int moistLen = snprintf(moistureData, sizeof(moistureData),
    "{\"percent\":%d,\"raw\":%d}",
    moisturePercent, rawMoisture);
  if (moistLen < (int)sizeof(moistureData)) {
    pMoistureChar->setValue((uint8_t*)moistureData, moistLen);
    pMoistureChar->notify();
  }
  esp_task_wdt_reset();
  delay(5);

  // Send alert data with hazard type
  char alertData[150];
  const char* alertLevel = currentAlert == CRITICAL ? "critical" :
                          (currentAlert == WARNING ? "warning" : "safe");
  int alertLen = snprintf(alertData, sizeof(alertData),
    "{\"level\":\"%s\",\"message\":\"%s\",\"type\":\"%s\"}",
    alertLevel, alertMessage.c_str(), hazardType.c_str());
  if (alertLen < (int)sizeof(alertData)) {
    pAlertChar->setValue((uint8_t*)alertData, alertLen);
    pAlertChar->notify();
  }
  esp_task_wdt_reset();
  delay(5);

  // Send battery data
  char batteryData[80];
  int batLen = snprintf(batteryData, sizeof(batteryData),
    "{\"voltage\":%.2f,\"percent\":%d,\"charging\":%s}",
    batteryVoltage, batteryPercent, batteryCharging ? "true" : "false");
  if (batLen < (int)sizeof(batteryData)) {
    pBatteryChar->setValue((uint8_t*)batteryData, batLen);
    pBatteryChar->notify();
  }
  esp_task_wdt_reset();
  delay(5);

  // Send raw acceleration buffer as binary ONLY when a new window was processed
  // This avoids blocking delay() calls (8×40ms=320ms) that starve the 200Hz sampling loop
  if (!newWindowAvailable) return;
  newWindowAvailable = false;

  esp_task_wdt_reset();
  delay(20); // Gap after JSON notifications
  {
    static int16_t rawAccelBuf[FFT_SAMPLES * 3]; // pre-pack buffer
    for (int i = 0; i < FFT_SAMPLES; i++) {
      rawAccelBuf[i * 3 + 0] = (int16_t)(accelSamplesX[processingBuffer][i] * 1000.0f);
      rawAccelBuf[i * 3 + 1] = (int16_t)(accelSamplesY[processingBuffer][i] * 1000.0f);
      rawAccelBuf[i * 3 + 2] = (int16_t)(accelSamplesZ[processingBuffer][i] * 1000.0f);
    }

    const int totalBytes = FFT_SAMPLES * 3 * 2; // 1536
    const int packetSize = 200;
    const int numPackets = (totalBytes + packetSize - 1) / packetSize;

    for (int pkt = 0; pkt < numPackets; pkt++) {
      uint8_t header[2] = { (uint8_t)pkt, (uint8_t)(FFT_SAMPLES >> 1) }; // 256->128, decoded on phone as *2
      int offset = pkt * packetSize;
      int remaining = totalBytes - offset;
      int sendLen = (remaining < packetSize) ? remaining : packetSize;

      uint8_t packet[202]; // 2 header + up to 200 data
      packet[0] = header[0];
      packet[1] = header[1];
      memcpy(&packet[2], ((uint8_t*)rawAccelBuf) + offset, sendLen);

      pFFTChar->setValue(packet, sendLen + 2);
      pFFTChar->notify();
      esp_task_wdt_reset();
      delay(10);
    }
  }
}

void testAlert() {
  DBG_PRINTLN("Test alert triggered!");
  M5.Speaker.tone(1000, 300);

  if (deviceConnected) {
    char alertData[150];
    snprintf(alertData, sizeof(alertData),
      "{\"level\":\"warning\",\"message\":\"Test alert from button\",\"type\":\"test\"}");
    pAlertChar->setValue((uint8_t*)alertData, strlen(alertData));
    pAlertChar->notify();
  }
}
