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

// ===================== P79: BLE CALIBRATE COMMAND =====================
bool g_calibrating = false;      // True during active calibration period
uint32_t g_calibStartMs = 0;     // millis() when calibration started

// ===================== P80: AUTOMATIC GAIN CONTROL =====================
static bool g_highGainMode = false;  // True when IMU is in ±16g range

// ===================== GLOBALS =====================
BLEServer* pServer = NULL;
BLECharacteristic* pIMUChar = NULL;
BLECharacteristic* pMoistureChar = NULL;
BLECharacteristic* pAlertChar = NULL;
BLECharacteristic* pBatteryChar = NULL;
BLECharacteristic* pFFTChar = NULL;  // Now used for raw accel binary
BLECharacteristic* pCmdChar = NULL;  // P79: writable command characteristic
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
    }
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

  // Initialize IMU
  M5.Imu.begin();
  DBG_PRINTLN("IMU initialized");

  // P78: Self-test — read one IMU sample to verify sensor is alive
  {
    float stX = 0, stY = 0, stZ = 0;
    M5.Imu.getAccelData(&stX, &stY, &stZ);
    bool selfTestPass = (stX != 0.0f || stY != 0.0f || stZ != 0.0f);
    M5.Lcd.fillScreen(BLACK);
    M5.Lcd.setTextSize(2);
    M5.Lcd.setTextColor(selfTestPass ? TFT_GREEN : RED, BLACK);
    M5.Lcd.setCursor(10, 50);
    if (selfTestPass) {
      M5.Lcd.println("SELF-TEST: PASS");
    } else {
      M5.Lcd.println("SELF-TEST: FAIL");
    }
    M5.Lcd.setTextColor(WHITE, BLACK);
    delay(2000);
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

  // Initialize BLE
  setupBLE();

  // Initialize watchdog timer (5 second timeout, panic on expiry)
  esp_task_wdt_init(5, true);
  esp_task_wdt_add(NULL); // Add current task (loopTask)

  delay(1000);
  M5.Lcd.fillScreen(BLACK);

  // P82: record time when device enters ready/safe state
  g_safeSinceMs = millis();

  // P81: Serial diagnostic banner for field operators
  Serial.println("=== AncientVision v" FW_VERSION " ===");
  Serial.printf("Boot count: %lu\n", (unsigned long)g_bootCount);
  Serial.printf("BLE name: AncientVision\n");
  Serial.println("IMU: OK");
  Serial.println("Ready.");

  lastSampleTime = micros();
}

void setupBLE() {
  DBG_PRINTLN("Starting BLE...");

  BLEDevice::init("AncientVision-Sensor");
  BLEDevice::setMTU(517); // Allow large payloads

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // 6 characteristics × 3 handles each (decl+value+CCCD) + 1 service = 19 minimum; 24 for margin
  BLEService *pService = pServer->createService(BLEUUID(SERVICE_UUID), 24);

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
  esp_task_wdt_reset();
  M5.update();

  unsigned long currentMicros = micros();
  unsigned long currentMillis = millis();

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
  }

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
  }

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
}

// ===================== HIGH-SPEED SAMPLING =====================
void collectSample() {
  // Read IMU accelerometer AND gyroscope
  M5.Imu.getAccelData(&accX, &accY, &accZ);
  M5.Imu.getGyroData(&gyroX, &gyroY, &gyroZ);

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
  } else if (vibrationPPV < 0.5f && g_highGainMode) {
    setAccelRange(4);    // Restore ±4g for better resolution
    g_highGainMode = false;
    DBG_PRINTLN("AGC: switched to ±4g range");
    Serial.println("AGC: normal range restored");
  }

  // In low power mode: skip heavy logging if vibration is safely low
  // but do NOT return — let execution continue to classifyHazard() for moisture checks
  if (lowPowerMode && vibrationPPV <= PPV_SAFE_MAX) {
    DBG_PRINTF("LP: PPV=%.1fmm/s (safe) STA/LTA=%.2f\n", vibrationPPV, staLtaRatio);
  }

  DBG_PRINTF("DSP v5.0: RMS=%.4fg PPV=%.1fmm/s Crest=%.1f STA/LTA=%.2f\n",
    vibrationRMS, vibrationPPV, crestFactor, staLtaRatio);
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
      } else if (currentAlert == WARNING) {
        M5.Speaker.tone(500, 200);
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

// ===================== DISPLAY (Archaeologist-friendly) =====================
void updateDisplay() {
  uint16_t bgColor;
  switch (currentAlert) {
    case CRITICAL: bgColor = RED; break;
    case WARNING:  bgColor = ORANGE; break;
    default:       bgColor = TFT_DARKGREEN; break;
  }

  M5.Lcd.fillScreen(bgColor);
  M5.Lcd.setTextColor(WHITE, bgColor);

  // Row 1: Title + BLE + Battery %
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(5, 2);
  if (lowPowerMode) {
    M5.Lcd.setTextColor(YELLOW, bgColor);
    M5.Lcd.print("LOW POWER");
    M5.Lcd.setTextColor(WHITE, bgColor);
  } else {
    M5.Lcd.print("AncientVision");
  }
  M5.Lcd.setCursor(175, 2);
  M5.Lcd.printf("%s%d%%", deviceConnected ? "BT" : "--", batteryPercent);

  // Row 2: Large safety status word
  M5.Lcd.setTextSize(3);
  M5.Lcd.setCursor(5, 24);
  if (!ppvCalibrated) {
    M5.Lcd.setTextColor(YELLOW, bgColor);
    M5.Lcd.print("CALIBRATING");
    M5.Lcd.setTextColor(WHITE, bgColor);
  } else if (currentAlert == CRITICAL) {
    M5.Lcd.setTextColor(YELLOW, bgColor);
    M5.Lcd.print("DANGER!");
  } else if (currentAlert == WARNING) {
    M5.Lcd.print("CAUTION");
  } else {
    M5.Lcd.print("SAFE");
  }
  M5.Lcd.setTextColor(WHITE, bgColor);

  // Row 3: Vibration level with visual bar and trend arrow
  // P77: compute trend character based on previous PPV reading
  char trendChar = (vibrationPPV > g_lastPpv * 1.05f) ? '^' :
                   (vibrationPPV < g_lastPpv * 0.95f) ? 'v' : '-';
  g_lastPpv = vibrationPPV;

  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(5, 52);
  M5.Lcd.print("Vibr:");
  const int barX = 65, barW = 110, barH = 12;
  int filled = constrain((int)(vibrationPPV / PPV_STRUCTURAL_DAMAGE * barW), 0, barW);
  uint16_t barColor = (vibrationPPV < 3.0f) ? TFT_GREEN :
                      (vibrationPPV < PPV_STRUCTURAL_DAMAGE) ? YELLOW : RED;
  M5.Lcd.fillRect(barX, 54, filled, barH, barColor);
  M5.Lcd.fillRect(barX + filled, 54, barW - filled, barH, TFT_DARKGREY);
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(180, 54);
  M5.Lcd.printf("%.1f%c", vibrationPPV, trendChar);

  // Row 4: Alert description or all-clear
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(5, 74);
  if (currentAlert != SAFE) {
    if (currentAlert == CRITICAL) M5.Lcd.setTextColor(YELLOW, bgColor);
    String displayMsg = alertMessage;
    if (displayMsg.length() > 20) displayMsg = displayMsg.substring(0, 20);
    M5.Lcd.print(displayMsg);
    M5.Lcd.setTextColor(WHITE, bgColor);
  } else {
    M5.Lcd.print("No hazards detected");
  }

  // Row 5: Soil moisture + Temperature
  M5.Lcd.setCursor(5, 96);
  M5.Lcd.printf("Soil:%d%%", moisturePercent);
  if (moisturePercent < MOISTURE_MIN_SAFE) {
    M5.Lcd.setTextColor(YELLOW, bgColor);
    M5.Lcd.print(" DRY");
  } else if (moisturePercent > MOISTURE_MAX_SAFE) {
    M5.Lcd.setTextColor(YELLOW, bgColor);
    M5.Lcd.print(" WET!");
  } else {
    M5.Lcd.print(" OK");
  }
  M5.Lcd.setTextColor(WHITE, bgColor);
  M5.Lcd.printf("  %.0fC", imuTemp);

  // Row 6: Four-line info strip (size 1 = 8px per line, fits 4 lines 118..134)
  // P77: PPV with trend, events, firmware version, boot count
  M5.Lcd.setTextSize(1);
  M5.Lcd.setTextColor(WHITE, bgColor);

  // Line 1: PPV with trend arrow
  M5.Lcd.setCursor(5, 110);
  M5.Lcd.printf("PPV:%.1fmm/s %c  Bat:%d%%%s",
    vibrationPPV, trendChar,
    batteryPercent, batteryCharging ? "+" : "");

  // Line 2: Event count for this session
  M5.Lcd.setCursor(5, 119);
  M5.Lcd.printf("Events: %lu", (unsigned long)g_sessionEvts);

  // Line 3: Firmware version
  M5.Lcd.setCursor(5, 128);
  M5.Lcd.printf("FW: " FW_VERSION);

  // Line 4: Boot count (persists across deep sleep)
  M5.Lcd.setCursor(120, 128);
  M5.Lcd.printf("Boot:%lu", (unsigned long)g_bootCount);
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
  //                 + cal(1) + gain(2) + chg(1) + overhead
  char imuData[300];
  uint32_t evtMs = g_evtActive ? (uint32_t)(millis() - g_evtStartMs) : 0u;
  int imuLen = snprintf(imuData, sizeof(imuData),
    "{\"ppv\":%.1f,\"stalta\":%.2f,\"rms\":%.4f,\"peak\":%.4f,\"crest\":%.1f,\"temp\":%.1f,\"mag\":%.4f"
    ",\"fw\":\"" FW_VERSION "\",\"seq\":%lu,\"evtMs\":%lu,\"boots\":%lu,\"evts\":%lu"
    ",\"cal\":%d,\"gain\":%d,\"chg\":%d}",
    vibrationPPV, staLtaRatio, vibrationRMS, vibrationPeak, crestFactor, imuTemp, vibrationMagnitude,
    (unsigned long)g_seq, (unsigned long)evtMs, (unsigned long)g_bootCount, (unsigned long)g_sessionEvts,
    g_calibrating ? 1 : 0, g_highGainMode ? 16 : 4, batteryCharging ? 1 : 0);
  // Use imuLen for setValue length (not strlen) to avoid re-scanning
  if (imuLen >= (int)sizeof(imuData)) {
    // Truncated — skip sending corrupt data
    DBG_PRINTF("BLE: IMU JSON truncated, skipping send\n");
  } else {
    pIMUChar->setValue((uint8_t*)imuData, imuLen);
    pIMUChar->notify();
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
