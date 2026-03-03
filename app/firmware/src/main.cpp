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

// Velocity drift HPF at 0.3 Hz, 200 Hz sample rate (per-axis)
BiquadFilter velHpfX = { 0.99335f, -1.98671f, 0.99335f, -1.98667f, 0.98675f, 0,0,0,0 };
BiquadFilter velHpfY = { 0.99335f, -1.98671f, 0.99335f, -1.98667f, 0.98675f, 0,0,0,0 };
BiquadFilter velHpfZ = { 0.99335f, -1.98671f, 0.99335f, -1.98667f, 0.98675f, 0,0,0,0 };

// ===================== GLOBALS =====================
BLEServer* pServer = NULL;
BLECharacteristic* pIMUChar = NULL;
BLECharacteristic* pMoistureChar = NULL;
BLECharacteristic* pAlertChar = NULL;
BLECharacteristic* pBatteryChar = NULL;
BLECharacteristic* pFFTChar = NULL;  // Now used for raw accel binary
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
float crestFactor = 0;               // Peak / RMS ratio
float vibrationMagnitude = 0;        // Legacy: raw magnitude for backward compat

// Recursive STA/LTA state (no arrays, saves memory)
float staValue = 0;
float ltaValue = 0.001f;             // Initialize to small value to avoid div-by-zero
float staLtaRatio = 0;
bool staLtaTriggered = false;

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

// Sample collection - tri-axial buffers
int sampleIndex = 0;
float accelSamplesX[FFT_SAMPLES];
float accelSamplesY[FFT_SAMPLES];
float accelSamplesZ[FFT_SAMPLES];
float velocitySamplesX[FFT_SAMPLES];
float velocitySamplesY[FFT_SAMPLES];
float velocitySamplesZ[FFT_SAMPLES];
unsigned long lastSampleTime = 0;
bool windowReady = false;

// Filter warm-up
int windowCount = 0;

// Timing
unsigned long lastBLESend = 0;
unsigned long lastDisplayUpdate = 0;
unsigned long lastMoistureRead = 0;
unsigned long lastBatteryRead = 0;
const int BLE_INTERVAL = 500;        // Send BLE every 500ms
const int DISPLAY_INTERVAL = 250;    // Update display 4x/sec
const int MOISTURE_INTERVAL = 1000;  // Read moisture every 1s
const int BATTERY_INTERVAL = 2000;   // Read battery every 2s

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

// ===================== SETUP =====================
void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);

  Serial.begin(115200);
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

  // Configure DLPF for 99 Hz anti-aliasing
  configureDLPF();

  // Initialize Madgwick filter at 200 Hz
  madgwickFilter.begin(SAMPLE_RATE);

  // Reset all filters
  hpFilterX.reset(); hpFilterY.reset(); hpFilterZ.reset();
  lpFilterX.reset(); lpFilterY.reset(); lpFilterZ.reset();
  velHpfX.reset(); velHpfY.reset(); velHpfZ.reset();

  // Initialize sample buffers
  memset(accelSamplesX, 0, sizeof(accelSamplesX));
  memset(accelSamplesY, 0, sizeof(accelSamplesY));
  memset(accelSamplesZ, 0, sizeof(accelSamplesZ));
  memset(velocitySamplesX, 0, sizeof(velocitySamplesX));
  memset(velocitySamplesY, 0, sizeof(velocitySamplesY));
  memset(velocitySamplesZ, 0, sizeof(velocitySamplesZ));
  sampleIndex = 0;
  windowCount = 0;

  // Read initial IMU temperature
  readIMUTemperature();

  // Initialize moisture sensor pin
  pinMode(MOISTURE_PIN, INPUT);
  DBG_PRINTLN("Moisture sensor initialized");

  // Initialize BLE
  setupBLE();

  delay(1000);
  M5.Lcd.fillScreen(BLACK);

  lastSampleTime = micros();
}

void setupBLE() {
  DBG_PRINTLN("Starting BLE...");

  BLEDevice::init("AncientVision-Sensor");
  BLEDevice::setMTU(517); // Allow large payloads

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

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

  // ---- Handle BLE connection changes ----
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    DBG_PRINTLN("Restart advertising");
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
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

  // Store filtered samples per axis
  accelSamplesX[sampleIndex] = filtX;
  accelSamplesY[sampleIndex] = filtY;
  accelSamplesZ[sampleIndex] = filtZ;

  // Integrate acceleration to velocity per axis (trapezoidal rule)
  // Convert g to mm/s^2: 1g = 9810 mm/s^2
  float dt = 1.0f / SAMPLE_RATE;
  if (sampleIndex > 0) {
    int prev = sampleIndex - 1;
    velocitySamplesX[sampleIndex] = velocitySamplesX[prev] +
      0.5f * (accelSamplesX[prev] * 9810.0f + filtX * 9810.0f) * dt;
    velocitySamplesY[sampleIndex] = velocitySamplesY[prev] +
      0.5f * (accelSamplesY[prev] * 9810.0f + filtY * 9810.0f) * dt;
    velocitySamplesZ[sampleIndex] = velocitySamplesZ[prev] +
      0.5f * (accelSamplesZ[prev] * 9810.0f + filtZ * 9810.0f) * dt;

    // Apply proper HPF to remove velocity drift (0.3 Hz Butterworth)
    velocitySamplesX[sampleIndex] = velHpfX.process(velocitySamplesX[sampleIndex]);
    velocitySamplesY[sampleIndex] = velHpfY.process(velocitySamplesY[sampleIndex]);
    velocitySamplesZ[sampleIndex] = velHpfZ.process(velocitySamplesZ[sampleIndex]);
  } else {
    velocitySamplesX[0] = 0;
    velocitySamplesY[0] = 0;
    velocitySamplesZ[0] = 0;
  }

  // Recursive STA/LTA computation (no arrays, saves memory)
  float mag = filtX * filtX + filtY * filtY + filtZ * filtZ;
  float sampleEnergy = mag;  // Already squared magnitude
  staValue = STA_ALPHA * sampleEnergy + (1.0f - STA_ALPHA) * staValue;
  ltaValue = LTA_ALPHA * sampleEnergy + (1.0f - LTA_ALPHA) * ltaValue;
  staLtaRatio = (ltaValue > 1e-10f) ? staValue / ltaValue : 1.0f;

  // Legacy backward compat: magnitude
  vibrationMagnitude = sqrt(mag);

  sampleIndex++;

  // When buffer is full, trigger processing
  if (sampleIndex >= FFT_SAMPLES) {
    sampleIndex = 0;
    windowReady = true;
  }
}

// ===================== VIBRATION ANALYSIS =====================
void processVibrationWindow() {
  // Filter warm-up: discard first 2 windows
  windowCount++;
  if (windowCount <= 2) {
    DBG_PRINTF("DSP: Discarding warm-up window %d/2\n", windowCount);
    return;
  }

  // ---- Compute RMS, Peak, PPV (tri-axial PCPV) ----
  float sumSq = 0;
  float peak = 0;
  float peakVelX = 0, peakVelY = 0, peakVelZ = 0;

  for (int i = 0; i < FFT_SAMPLES; i++) {
    // Combined magnitude for RMS
    float magSq = accelSamplesX[i] * accelSamplesX[i] +
                  accelSamplesY[i] * accelSamplesY[i] +
                  accelSamplesZ[i] * accelSamplesZ[i];
    sumSq += magSq;
    float magVal = sqrt(magSq);
    if (magVal > peak) peak = magVal;

    // Per-axis peak velocity for PCPV
    float absVelX = fabs(velocitySamplesX[i]);
    float absVelY = fabs(velocitySamplesY[i]);
    float absVelZ = fabs(velocitySamplesZ[i]);
    if (absVelX > peakVelX) peakVelX = absVelX;
    if (absVelY > peakVelY) peakVelY = absVelY;
    if (absVelZ > peakVelZ) peakVelZ = absVelZ;
  }

  vibrationRMS = sqrt(sumSq / FFT_SAMPLES);
  vibrationPeak = peak;

  // PCPV: max of per-axis peak velocities (DIN 4150-3 method)
  vibrationPPV = max(peakVelX, max(peakVelY, peakVelZ));

  // ---- Crest Factor ----
  crestFactor = (vibrationRMS > 0.0001f) ? vibrationPeak / vibrationRMS : 1.0f;

  // In low power mode: skip if vibration is safely low
  if (lowPowerMode && vibrationPPV <= PPV_SAFE_MAX) {
    DBG_PRINTF("LP: PPV=%.1fmm/s (safe) STA/LTA=%.2f\n", vibrationPPV, staLtaRatio);
    return;
  }

  DBG_PRINTF("DSP v5.0: RMS=%.4fg PPV=%.1fmm/s Crest=%.1f STA/LTA=%.2f\n",
    vibrationRMS, vibrationPPV, crestFactor, staLtaRatio);
}

// ===================== HAZARD CLASSIFICATION (Simplified + Hysteresis) =====================
void classifyHazard() {
  // Skip classification during warm-up
  if (windowCount <= 2) return;

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

      if (currentAlert == CRITICAL) {
        M5.Speaker.tone(1000, 500);
      } else if (currentAlert == WARNING) {
        M5.Speaker.tone(500, 200);
      }

      DBG_PRINTF("ALERT CONFIRMED: %s [%s] type=%s\n",
        currentAlert == CRITICAL ? "CRITICAL" : "WARNING",
        alertMessage.c_str(), hazardType.c_str());
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

  // Calculate percentage based on LiPo discharge curve
  if (batteryVoltage >= 4.1) {
    batteryPercent = 100;
  } else if (batteryVoltage >= 3.7) {
    batteryPercent = (int)((batteryVoltage - 3.7) / 0.4 * 50.0 + 50.0);
  } else if (batteryVoltage >= 3.0) {
    batteryPercent = (int)((batteryVoltage - 3.0) / 0.7 * 50.0);
  } else {
    batteryPercent = 0;
  }

  batteryPercent = constrain(batteryPercent, 0, 100);
  batteryCharging = (batteryVoltage > 4.2);
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
  if (currentAlert == CRITICAL) {
    M5.Lcd.setTextColor(YELLOW, bgColor);
    M5.Lcd.print("DANGER!");
  } else if (currentAlert == WARNING) {
    M5.Lcd.print("CAUTION");
  } else {
    M5.Lcd.print("SAFE");
  }
  M5.Lcd.setTextColor(WHITE, bgColor);

  // Row 3: Vibration level with visual bar
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(5, 52);
  M5.Lcd.print("Vibr:");
  const int barX = 65, barW = 130, barH = 12;
  int filled = constrain((int)(vibrationPPV / PPV_STRUCTURAL_DAMAGE * barW), 0, barW);
  uint16_t barColor = (vibrationPPV < 3.0f) ? TFT_GREEN :
                      (vibrationPPV < PPV_STRUCTURAL_DAMAGE) ? YELLOW : RED;
  M5.Lcd.fillRect(barX, 54, filled, barH, barColor);
  M5.Lcd.fillRect(barX + filled, 54, barW - filled, barH, TFT_DARKGREY);
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(200, 54);
  M5.Lcd.printf("%.1f", vibrationPPV);

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

  // Row 6: Battery + charging status
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(5, 118);
  M5.Lcd.setTextColor(batteryPercent < 20 ? RED : (batteryCharging ? TFT_CYAN : WHITE), bgColor);
  M5.Lcd.printf("Battery: %d%%  %.2fV %s", batteryPercent, batteryVoltage, batteryCharging ? "Charging" : "");
}

// ===================== BLE FUNCTIONS =====================
void sendBLEData() {
  if (!deviceConnected) return;

  // Send simplified IMU JSON (only firmware-computed features)
  char imuData[192];
  int imuLen = snprintf(imuData, sizeof(imuData),
    "{\"ppv\":%.1f,\"stalta\":%.2f,\"rms\":%.4f,\"peak\":%.4f,\"crest\":%.1f,\"temp\":%.1f,\"mag\":%.4f}",
    vibrationPPV, staLtaRatio, vibrationRMS, vibrationPeak, crestFactor, imuTemp, vibrationMagnitude);
  if (imuLen >= (int)sizeof(imuData)) {
    DBG_PRINTF("BLE WARNING: IMU JSON truncated (%d >= %d)\n", imuLen, (int)sizeof(imuData));
  }
  pIMUChar->setValue((uint8_t*)imuData, strlen(imuData));
  pIMUChar->notify();
  delay(20);

  // Send moisture data
  char moistureData[50];
  snprintf(moistureData, sizeof(moistureData),
    "{\"percent\":%d,\"raw\":%d}",
    moisturePercent, rawMoisture);
  pMoistureChar->setValue((uint8_t*)moistureData, strlen(moistureData));
  pMoistureChar->notify();
  delay(20);

  // Send alert data with hazard type
  char alertData[150];
  const char* alertLevel = currentAlert == CRITICAL ? "critical" :
                          (currentAlert == WARNING ? "warning" : "safe");
  snprintf(alertData, sizeof(alertData),
    "{\"level\":\"%s\",\"message\":\"%s\",\"type\":\"%s\"}",
    alertLevel, alertMessage.c_str(), hazardType.c_str());
  pAlertChar->setValue((uint8_t*)alertData, strlen(alertData));
  pAlertChar->notify();
  delay(20);

  // Send battery data
  char batteryData[80];
  snprintf(batteryData, sizeof(batteryData),
    "{\"voltage\":%.2f,\"percent\":%d,\"charging\":%s}",
    batteryVoltage, batteryPercent, batteryCharging ? "true" : "false");
  pBatteryChar->setValue((uint8_t*)batteryData, strlen(batteryData));
  pBatteryChar->notify();
  delay(20);

  // Send raw acceleration buffer as binary (for phone-side DSP)
  // Format: [seqNum(u8), sampleCount(u8), data...]
  // Data: 256 * 3 axes * int16 = 1536 bytes, split into 3 packets of 512 bytes
  {
    static int16_t rawAccelBuf[FFT_SAMPLES * 3]; // pre-pack buffer
    for (int i = 0; i < FFT_SAMPLES; i++) {
      rawAccelBuf[i * 3 + 0] = (int16_t)(accelSamplesX[i] * 1000.0f);
      rawAccelBuf[i * 3 + 1] = (int16_t)(accelSamplesY[i] * 1000.0f);
      rawAccelBuf[i * 3 + 2] = (int16_t)(accelSamplesZ[i] * 1000.0f);
    }

    const int totalBytes = FFT_SAMPLES * 3 * 2; // 1536
    const int packetSize = 512;
    const int numPackets = (totalBytes + packetSize - 1) / packetSize;

    for (int pkt = 0; pkt < numPackets; pkt++) {
      uint8_t header[2] = { (uint8_t)pkt, (uint8_t)FFT_SAMPLES };
      int offset = pkt * packetSize;
      int remaining = totalBytes - offset;
      int sendLen = (remaining < packetSize) ? remaining : packetSize;

      uint8_t packet[514]; // 2 header + up to 512 data
      packet[0] = header[0];
      packet[1] = header[1];
      memcpy(&packet[2], ((uint8_t*)rawAccelBuf) + offset, sendLen);

      pFFTChar->setValue(packet, sendLen + 2);
      pFFTChar->notify();
      delay(20);
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
