/*
 * AncientVision Trench Safety Monitor v4.0
 * For M5StickC Plus 2 with Soil Moisture Sensor
 *
 * v4.0 Upgrades over v3.0:
 * - Arias Intensity (running computation, auto-reset every 60s or via BLE)
 * - Cumulative Absolute Velocity (CAV) with EPRI threshold (0.16 g·s)
 * - Recursive STA/LTA (no arrays, saves memory)
 * - 3-Level Haar DWT for transient detection (alongside FFT)
 * - IMU temperature compensation (MPU6886 bias correction)
 * - Extended BLE JSON with 17 fields (was 11)
 *
 * v3.0 Features (retained):
 * - Madgwick quaternion gravity removal (accurate at any orientation)
 * - Tri-axial PCPV per DIN 4150-3 (proper 3-axis PPV)
 * - 2nd-order Butterworth HPF on velocity (replaces crude 0.998 decay)
 * - FFT adaptive noise floor threshold
 * - Kurtosis computation (4th moment for impact detection)
 * - Hysteresis alert state machine with cooldown
 * - Filter warm-up discard (first 2 windows)
 *
 * Signal Processing Pipeline:
 *   Raw IMU (200Hz) -> Temp Compensation -> DLPF (99Hz) -> Madgwick Gravity Removal
 *   -> Butterworth Bandpass (0.5-100Hz) per axis -> FFT (256-pt) + Haar DWT (3-level)
 *   -> Tri-axial PPV + Velocity HPF -> Recursive STA/LTA + Kurtosis
 *   -> Arias Intensity + CAV -> DIN 4150-3 Classification (Hysteresis)
 *
 * Libraries Required:
 * - M5StickCPlus2 (Arduino Library Manager)
 * - arduinoFFT (Arduino Library Manager)
 * - MadgwickAHRS (Arduino Library Manager, by Arduino)
 */

#include <M5Unified.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <arduinoFFT.h>
#include <MadgwickAHRS.h>
#include <Wire.h>

// ===================== CONFIGURATION =====================

// Sampling Configuration
const int SAMPLE_RATE = 200;             // 200 Hz IMU sampling
const int SAMPLE_INTERVAL_US = 5000;     // 5ms = 200 Hz (in microseconds)
const int FFT_SAMPLES = 256;             // FFT window size
const float FFT_WINDOW_SEC = (float)FFT_SAMPLES / SAMPLE_RATE;  // 1.28s

// Soil Moisture Thresholds (safe range: 30-60%)
const int MOISTURE_MIN_SAFE = 30;
const int MOISTURE_MAX_SAFE = 60;

// Sensor Pin
const int MOISTURE_PIN = 33;

// Calibration values for soil moisture sensor
const int MOISTURE_AIR = 3500;
const int MOISTURE_WATER = 1500;

// DIN 4150-3 PPV Thresholds (mm/s) for heritage structures
const float PPV_SAFE_MAX = 0.3;          // Below human perception
const float PPV_HERITAGE_LOW = 3.0;      // Heritage limit 1-10 Hz
const float PPV_HERITAGE_HIGH = 8.0;     // Heritage limit 50-100 Hz
const float PPV_STRUCTURAL_DAMAGE = 10.0; // Structural damage risk
const float PPV_CONTINUOUS_LIMIT = 2.5;  // Continuous vibration limit

// Crest factor threshold for impact detection
const float CREST_IMPACT_THRESHOLD = 5.0;

// Spectral centroid shift threshold (50% change)
const float CENTROID_SHIFT_THRESHOLD = 0.5;

// STA/LTA Configuration (recursive - no arrays needed)
const float STA_ALPHA = 1.0f / 40.0f;    // Equivalent to 40-sample window (0.2s at 200Hz)
const float LTA_ALPHA = 1.0f / 2000.0f;  // Equivalent to 2000-sample window (10s at 200Hz)
const float STA_TRIGGER = 4.0;    // STA/LTA trigger ratio
const float STA_DETRIGGER = 1.5;  // STA/LTA de-trigger ratio

// CAV damage threshold (EPRI)
const float CAV_DAMAGE_THRESHOLD = 0.16;  // g·s

// Arias Intensity reset interval (milliseconds)
const unsigned long ARIAS_RESET_INTERVAL_MS = 60000;  // 60 seconds

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
#define CHAR_BATTERY_UUID   "beb5483e-36e1-4688-b7f5-ea07361b26ab"  // v4.1: Battery level
#define CHAR_FFT_UUID       "beb5483e-36e1-4688-b7f5-ea07361b26ac"  // v4.2: FFT bins

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
// 2nd-order Butterworth HPF coefficients computed via bilinear transform
// fc=0.3 Hz, fs=200 Hz -> w0 = 2*pi*0.3/200 = 0.009425
// Pre-warp: tan(w0/2) = 0.004713 -> K = 0.004713
// b0 = 1/(1+sqrt(2)*K+K^2) ≈ 0.99335
BiquadFilter velHpfX = { 0.99335f, -1.98671f, 0.99335f, -1.98667f, 0.98675f, 0,0,0,0 };
BiquadFilter velHpfY = { 0.99335f, -1.98671f, 0.99335f, -1.98667f, 0.98675f, 0,0,0,0 };
BiquadFilter velHpfZ = { 0.99335f, -1.98671f, 0.99335f, -1.98667f, 0.98675f, 0,0,0,0 };

// ===================== FFT =====================
double vReal[FFT_SAMPLES];
double vImag[FFT_SAMPLES];
ArduinoFFT<double> FFT = ArduinoFFT<double>(vReal, vImag, FFT_SAMPLES, SAMPLE_RATE);

// ===================== DWT BUFFERS =====================
float dwtDetail1[128];  // Level 1 detail (50-100 Hz band at 200Hz Fs)
float dwtDetail2[64];   // Level 2 detail (25-50 Hz band)
float dwtDetail3[32];   // Level 3 detail (12.5-25 Hz band)
float dwtApprox[32];    // Level 3 approximation (0-12.5 Hz band)
float dwtEnergy1 = 0, dwtEnergy2 = 0, dwtEnergy3 = 0;

// ===================== GLOBALS =====================
BLEServer* pServer = NULL;
BLECharacteristic* pIMUChar = NULL;
BLECharacteristic* pMoistureChar = NULL;
BLECharacteristic* pAlertChar = NULL;
BLECharacteristic* pBatteryChar = NULL;
BLECharacteristic* pFFTChar = NULL;
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
float dominantFreq = 0;              // Dominant frequency (Hz)
float crestFactor = 0;               // Peak / RMS ratio
float spectralCentroid = 0;          // Frequency center of mass
float prevSpectralCentroid = 0;      // Previous centroid for shift detection
float kurtosis = 0;                  // Excess kurtosis (4th moment)
float vibrationMagnitude = 0;        // Legacy: raw magnitude for backward compat

// Recursive STA/LTA state (v4.0 - no arrays, saves memory)
float staValue = 0;
float ltaValue = 0.001f;             // Initialize to small value to avoid div-by-zero
float staLtaRatio = 0;
bool staLtaTriggered = false;

// Arias Intensity (v4.0 - running computation)
float ariasIntensity = 0.0f;
unsigned long ariasLastReset = 0;

// Cumulative Absolute Velocity (v4.0)
float cav = 0.0f;

// IMU Temperature (v4.0)
float imuTemp = 25.0f;               // Default to reference temperature
unsigned long lastTempRead = 0;
const int TEMP_READ_INTERVAL = 500;  // Read temperature every 500ms

// Moisture data
int moisturePercent = 0;
int rawMoisture = 0;

// Battery data (v4.1)
float batteryVoltage = 0.0;  // Battery voltage (V)
int batteryPercent = 100;    // Battery percentage (0-100%)
bool batteryCharging = false; // Charging status

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
unsigned long lastBatteryRead = 0;  // v4.1
const int BLE_INTERVAL = 500;        // Send BLE every 500ms
const int DISPLAY_INTERVAL = 250;    // Update display 4x/sec
const int MOISTURE_INTERVAL = 1000;  // Read moisture every 1s
const int BATTERY_INTERVAL = 2000;   // Read battery every 2s (v4.1)

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

  Serial.println("DLPF configured: 99 Hz bandwidth");
}

// ===================== IMU TEMPERATURE READING (v4.0) =====================
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

// ===================== 3-LEVEL HAAR DWT (v4.0) =====================
void computeHaarDWT(float* signal, int length) {
  float temp[256];
  memcpy(temp, signal, length * sizeof(float));

  int len = length;
  for (int level = 0; level < 3; level++) {
    int halfLen = len / 2;
    float* detail;
    if (level == 0) detail = dwtDetail1;
    else if (level == 1) detail = dwtDetail2;
    else detail = dwtDetail3;

    for (int i = 0; i < halfLen; i++) {
      float avg  = (temp[2 * i] + temp[2 * i + 1]) * 0.70710678f;  // 1/sqrt(2)
      float diff = (temp[2 * i] - temp[2 * i + 1]) * 0.70710678f;
      detail[i] = diff;
      temp[i] = avg;
    }
    len = halfLen;
  }
  memcpy(dwtApprox, temp, 32 * sizeof(float));
}

void computeDWTEnergy() {
  dwtEnergy1 = 0;
  dwtEnergy2 = 0;
  dwtEnergy3 = 0;
  for (int i = 0; i < 128; i++) dwtEnergy1 += dwtDetail1[i] * dwtDetail1[i];
  for (int i = 0; i < 64; i++)  dwtEnergy2 += dwtDetail2[i] * dwtDetail2[i];
  for (int i = 0; i < 32; i++)  dwtEnergy3 += dwtDetail3[i] * dwtDetail3[i];
}

// ===================== FORWARD DECLARATIONS =====================
void configureDLPF();
void readIMUTemperature();
void computeHaarDWT(float* signal, int length);
void computeDWTEnergy();
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
      Serial.println("Device connected!");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("Device disconnected!");
    }
};

// ===================== SETUP =====================
void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);

  Serial.begin(115200);
  Serial.println("AncientVision Trench Safety Monitor v4.0");
  Serial.println("DSP: Madgwick + Tri-axial PPV + Recursive STA/LTA + DWT + Arias + CAV");

  // Initialize display
  M5.Lcd.setRotation(1);
  M5.Lcd.fillScreen(BLACK);
  M5.Lcd.setTextSize(2);
  M5.Lcd.setTextColor(WHITE, BLACK);

  M5.Lcd.setCursor(10, 20);
  M5.Lcd.println("AncientVision");
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(10, 50);
  M5.Lcd.println("Vibration Analysis v4.0");
  M5.Lcd.setCursor(10, 65);
  M5.Lcd.println("Madgwick+FFT+DWT+STA/LTA");
  M5.Lcd.setCursor(10, 80);
  M5.Lcd.println("Arias+CAV+TempComp");
  M5.Lcd.setCursor(10, 100);
  M5.Lcd.println("Initializing...");

  // Initialize IMU
  M5.Imu.begin();
  Serial.println("IMU initialized");

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

  // Initialize v4.0 accumulators
  ariasIntensity = 0.0f;
  cav = 0.0f;
  ariasLastReset = millis();

  // Read initial IMU temperature
  readIMUTemperature();

  // Initialize moisture sensor pin
  pinMode(MOISTURE_PIN, INPUT);
  Serial.println("Moisture sensor initialized");

  // Initialize BLE
  setupBLE();

  delay(1000);
  M5.Lcd.fillScreen(BLACK);

  lastSampleTime = micros();
}

void setupBLE() {
  Serial.println("Starting BLE...");

  BLEDevice::init("AncientVision-Sensor");

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

  Serial.println("BLE ready - waiting for connection...");
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

  // ---- Process FFT window when ready ----
  if (windowReady) {
    windowReady = false;
    processVibrationWindow();
    classifyHazard();
  }

  // ---- Read IMU temperature periodically (v4.0) ----
  if (currentMillis - lastTempRead >= TEMP_READ_INTERVAL) {
    lastTempRead = currentMillis;
    readIMUTemperature();
  }

  // ---- Auto-reset Arias Intensity (v4.0) ----
  if (currentMillis - ariasLastReset >= ARIAS_RESET_INTERVAL_MS) {
    Serial.printf("Arias Intensity reset (was %.6f m/s, CAV was %.4f g*s)\n", ariasIntensity, cav);
    ariasIntensity = 0.0f;
    cav = 0.0f;
    ariasLastReset = currentMillis;
  }

  // ---- Read moisture at 1 Hz ----
  if (currentMillis - lastMoistureRead >= MOISTURE_INTERVAL) {
    lastMoistureRead = currentMillis;
    readMoisture();
  }

  // ---- Read battery at 0.5 Hz (v4.1) ----
  if (currentMillis - lastBatteryRead >= BATTERY_INTERVAL) {
    lastBatteryRead = currentMillis;
    readBattery();
  }

  // ---- Send BLE data at 2 Hz ----
  if (currentMillis - lastBLESend >= BLE_INTERVAL) {
    lastBLESend = currentMillis;
    sendBLEData();
  }

  // ---- Update display at 4 Hz ----
  if (currentMillis - lastDisplayUpdate >= DISPLAY_INTERVAL) {
    lastDisplayUpdate = currentMillis;
    updateDisplay();
  }

  // ---- Handle BLE connection changes ----
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println("Restart advertising");
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }

  // Button A: Manual alert test
  if (M5.BtnA.wasPressed()) {
    testAlert();
  }
}

// ===================== HIGH-SPEED SAMPLING =====================
void collectSample() {
  // Read IMU accelerometer AND gyroscope
  M5.Imu.getAccelData(&accX, &accY, &accZ);
  M5.Imu.getGyroData(&gyroX, &gyroY, &gyroZ);

  // v4.0: Temperature compensation - remove thermal bias from accelerometer
  float tempBias = (imuTemp - TEMP_REF) * TEMP_BIAS_COEFF;
  accX -= tempBias;
  accY -= tempBias;
  accZ -= tempBias;

  // Update Madgwick filter for orientation tracking
  // Madgwick expects gyro in degrees/sec, accel in any consistent unit
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

  // v4.0: Recursive STA/LTA computation (no arrays, saves ~8KB RAM)
  float mag = filtX * filtX + filtY * filtY + filtZ * filtZ;
  float sampleEnergy = mag;  // Already squared magnitude
  staValue = STA_ALPHA * sampleEnergy + (1.0f - STA_ALPHA) * staValue;
  ltaValue = LTA_ALPHA * sampleEnergy + (1.0f - LTA_ALPHA) * ltaValue;
  staLtaRatio = (ltaValue > 1e-10f) ? staValue / ltaValue : 1.0f;

  // v4.0: Arias Intensity accumulation (per filtered sample)
  // AI = (pi / 2g) * integral(a^2 dt), a in g, result in m/s
  float filteredAccelMag = sqrt(mag);  // magnitude in g
  ariasIntensity += (PI / (2.0f * 9.81f)) * filteredAccelMag * filteredAccelMag * dt;

  // v4.0: Cumulative Absolute Velocity accumulation
  // CAV = integral(|a| dt), in g·s
  cav += filteredAccelMag * dt;

  // Legacy backward compat: magnitude
  vibrationMagnitude = filteredAccelMag;

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
    Serial.printf("DSP: Discarding warm-up window %d/2\n", windowCount);
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

  // ---- Kurtosis (excess, computed on acceleration magnitude) ----
  {
    float mean = 0, m2 = 0, m4 = 0;
    for (int i = 0; i < FFT_SAMPLES; i++) {
      float magVal = sqrt(accelSamplesX[i] * accelSamplesX[i] +
                       accelSamplesY[i] * accelSamplesY[i] +
                       accelSamplesZ[i] * accelSamplesZ[i]);
      mean += magVal;
    }
    mean /= FFT_SAMPLES;
    for (int i = 0; i < FFT_SAMPLES; i++) {
      float magVal = sqrt(accelSamplesX[i] * accelSamplesX[i] +
                       accelSamplesY[i] * accelSamplesY[i] +
                       accelSamplesZ[i] * accelSamplesZ[i]);
      float d = magVal - mean;
      m2 += d * d;
      m4 += d * d * d * d;
    }
    m2 /= FFT_SAMPLES;
    m4 /= FFT_SAMPLES;
    kurtosis = (m2 > 0.00001f) ? (m4 / (m2 * m2)) - 3.0f : 0.0f;
  }

  // ---- FFT for frequency analysis (use magnitude of 3 axes) ----
  // Build magnitude signal for both FFT and DWT
  float magSignal[FFT_SAMPLES];
  for (int i = 0; i < FFT_SAMPLES; i++) {
    magSignal[i] = sqrt(accelSamplesX[i] * accelSamplesX[i] +
                        accelSamplesY[i] * accelSamplesY[i] +
                        accelSamplesZ[i] * accelSamplesZ[i]);
    vReal[i] = (double)magSignal[i];
    vImag[i] = 0;
  }

  // Apply Hanning window
  FFT.windowing(FFTWindow::Hann, FFTDirection::Forward);

  // Compute FFT
  FFT.compute(FFTDirection::Forward);

  // Convert to magnitudes
  FFT.complexToMagnitude();

  // ---- Adaptive noise floor ----
  int minBin = 1;   // Skip DC
  int maxBin = FFT_SAMPLES / 2;

  double magRMSSum = 0;
  for (int i = minBin; i < maxBin; i++) {
    magRMSSum += vReal[i] * vReal[i];
  }
  double noiseFloor = sqrt(magRMSSum / (maxBin - minBin)) * 3.0;  // 3x RMS

  // ---- Find dominant frequency (above noise floor) ----
  double maxMag = 0;
  int maxBinIdx = minBin;

  for (int i = minBin; i < maxBin; i++) {
    if (vReal[i] > maxMag) {
      maxMag = vReal[i];
      maxBinIdx = i;
    }
  }

  // Only report frequency if signal is above noise floor
  if (maxMag > noiseFloor) {
    dominantFreq = (float)maxBinIdx * SAMPLE_RATE / FFT_SAMPLES;
  } else {
    dominantFreq = 0;  // Below noise floor - no meaningful frequency
  }

  // ---- Spectral Centroid (only if signal above noise) ----
  prevSpectralCentroid = spectralCentroid;
  if (maxMag > noiseFloor) {
    double weightedSum = 0;
    double magnitudeSum = 0;
    for (int i = minBin; i < maxBin; i++) {
      float freq = (float)i * SAMPLE_RATE / FFT_SAMPLES;
      weightedSum += freq * vReal[i];
      magnitudeSum += vReal[i];
    }
    spectralCentroid = (magnitudeSum > 0.001) ? weightedSum / magnitudeSum : 0;
  } else {
    spectralCentroid = 0;
  }

  // ---- v4.0: 3-Level Haar DWT for transient detection ----
  computeHaarDWT(magSignal, FFT_SAMPLES);
  computeDWTEnergy();

  // Debug output
  Serial.printf("DSP v4.0: RMS=%.4fg PPV=%.1fmm/s Freq=%.1fHz Crest=%.1f Kurt=%.2f STA/LTA=%.2f Cent=%.1fHz\n",
    vibrationRMS, vibrationPPV, dominantFreq, crestFactor, kurtosis, staLtaRatio, spectralCentroid);
  Serial.printf("  Arias=%.6f CAV=%.4f Temp=%.1fC DWT=[%.4f,%.4f,%.4f]\n",
    ariasIntensity, cav, imuTemp, dwtEnergy1, dwtEnergy2, dwtEnergy3);
}

// ===================== HAZARD CLASSIFICATION (DIN 4150-3 + Hysteresis) =====================
void classifyHazard() {
  // Skip classification during warm-up
  if (windowCount <= 2) return;

  // ---- Evaluate rules to get candidate alert ----
  AlertState newAlert = SAFE;
  String newMessage = "";
  String newType = "none";

  // CRITICAL: Structural damage risk at any frequency
  if (vibrationPPV > PPV_STRUCTURAL_DAMAGE) {
    newAlert = CRITICAL;
    newMessage = "Structural damage risk - EVACUATE";
    newType = "structural";
  }
  // CRITICAL: Seismic activity (low frequency, high PPV)
  else if (vibrationPPV > PPV_HERITAGE_LOW && dominantFreq >= 0.5 && dominantFreq <= 10.0) {
    newAlert = CRITICAL;
    newMessage = "Seismic activity detected";
    newType = "seismic";
  }
  // CRITICAL: STA/LTA seismic trigger (independent of PPV thresholds)
  else if (staLtaRatio > STA_TRIGGER && vibrationPPV > 1.0) {
    newAlert = CRITICAL;
    newMessage = "Seismic event (STA/LTA)";
    newType = "seismic";
  }
  // CRITICAL: CAV exceeds EPRI damage threshold (v4.0)
  else if (cav > CAV_DAMAGE_THRESHOLD) {
    newAlert = CRITICAL;
    newMessage = "CAV damage threshold exceeded";
    newType = "cav_damage";
  }
  // WARNING: Heavy machinery (mid frequency, moderate PPV)
  else if (vibrationPPV > PPV_HERITAGE_LOW && dominantFreq > 10.0 && dominantFreq <= 50.0) {
    newAlert = WARNING;
    newMessage = "Heavy machinery nearby";
    newType = "machinery";
  }
  // WARNING: High-frequency structural stress
  else if (vibrationPPV > PPV_HERITAGE_HIGH && dominantFreq > 50.0) {
    newAlert = WARNING;
    newMessage = "High-freq structural stress";
    newType = "hf_stress";
  }
  // WARNING: Impact detected (high crest factor + high kurtosis)
  else if (crestFactor > CREST_IMPACT_THRESHOLD && vibrationPPV > 1.0) {
    newAlert = WARNING;
    newMessage = "Impact detected";
    newType = "impact";
  }
  // WARNING: DWT transient detection (v4.0 - high energy in detail level 1)
  else if (dwtEnergy1 > dwtEnergy3 * 10.0f && dwtEnergy1 > 0.01f && vibrationPPV > 0.5) {
    newAlert = WARNING;
    newMessage = "HF transient (DWT)";
    newType = "dwt_transient";
  }
  // WARNING: Continuous vibration exceeding heritage limit
  else if (vibrationPPV > PPV_CONTINUOUS_LIMIT) {
    newAlert = WARNING;
    newMessage = "Continuous vibration high";
    newType = "continuous";
  }
  // WARNING: Spectral centroid shift (vibration source changed)
  else if (prevSpectralCentroid > 1.0 && spectralCentroid > 1.0) {
    float shift = fabs(spectralCentroid - prevSpectralCentroid) / prevSpectralCentroid;
    if (shift > CENTROID_SHIFT_THRESHOLD && vibrationPPV > 0.5) {
      newAlert = WARNING;
      newMessage = "Vibration source changed";
      newType = "source_change";
    }
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

      Serial.printf("ALERT CONFIRMED: %s [%s] type=%s\n",
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

      Serial.printf("ALERT CLEARED -> %s\n",
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

// ===================== BATTERY MONITORING (v4.1) =====================
void readBattery() {
  // Read battery voltage from M5StickC Plus 2 power management
  batteryVoltage = M5.Power.getBatteryVoltage() / 1000.0;  // Convert mV to V

  // Calculate percentage based on LiPo discharge curve
  // 4.2V = 100%, 3.7V = 50%, 3.0V = 0%
  if (batteryVoltage >= 4.1) {
    batteryPercent = 100;
  } else if (batteryVoltage >= 3.7) {
    // Linear interpolation 3.7V-4.1V = 50-100%
    batteryPercent = (int)((batteryVoltage - 3.7) / 0.4 * 50.0 + 50.0);
  } else if (batteryVoltage >= 3.0) {
    // Linear interpolation 3.0V-3.7V = 0-50%
    batteryPercent = (int)((batteryVoltage - 3.0) / 0.7 * 50.0);
  } else {
    batteryPercent = 0;
  }

  batteryPercent = constrain(batteryPercent, 0, 100);

  // Check if charging (voltage is increasing or > 4.2V)
  batteryCharging = (batteryVoltage > 4.2);
}

// ===================== DISPLAY =====================
void updateDisplay() {
  uint16_t bgColor;
  switch (currentAlert) {
    case CRITICAL: bgColor = RED; break;
    case WARNING:  bgColor = ORANGE; break;
    default:       bgColor = TFT_DARKGREEN; break;
  }

  M5.Lcd.fillScreen(bgColor);
  M5.Lcd.setTextColor(WHITE, bgColor);

  // Row 1: Title + BLE + Battery
  int batLevel = M5.Power.getBatteryLevel();
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(5, 2);
  M5.Lcd.print("AncientVision");
  M5.Lcd.setCursor(175, 2);
  M5.Lcd.printf("%s%d%%", deviceConnected ? "BT" : "--", batLevel);

  // Row 2: PPV (the key metric)
  M5.Lcd.setTextSize(3);
  M5.Lcd.setCursor(5, 22);
  if (vibrationPPV < 10.0) {
    M5.Lcd.printf("PPV:%.1f", vibrationPPV);
  } else {
    M5.Lcd.printf("PPV:%.0f", vibrationPPV);
  }
  M5.Lcd.setTextSize(2);
  M5.Lcd.print("mm/s");

  // Row 3: Frequency + STA/LTA
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(5, 50);
  M5.Lcd.printf("%.0fHz S/L:%.1f", dominantFreq, staLtaRatio);

  // Row 4: Hazard type or status
  M5.Lcd.setCursor(5, 72);
  if (currentAlert == CRITICAL) {
    M5.Lcd.setTextColor(YELLOW, bgColor);
    String displayMsg = alertMessage;
    if (displayMsg.length() > 20) displayMsg = displayMsg.substring(0, 20);
    M5.Lcd.print(displayMsg);
  } else if (currentAlert == WARNING) {
    String displayMsg = alertMessage;
    if (displayMsg.length() > 20) displayMsg = displayMsg.substring(0, 20);
    M5.Lcd.print(displayMsg);
  } else {
    M5.Lcd.print("Safe - DIN 4150-3");
  }
  M5.Lcd.setTextColor(WHITE, bgColor);

  // Row 5: Moisture + Temperature (v4.0)
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(5, 94);
  M5.Lcd.printf("Mst:%d%%", moisturePercent);
  if (moisturePercent < MOISTURE_MIN_SAFE) {
    M5.Lcd.print(" DRY");
  } else if (moisturePercent > MOISTURE_MAX_SAFE) {
    M5.Lcd.print(" WET!");
  } else {
    M5.Lcd.print(" OK");
  }
  M5.Lcd.printf(" %.0fC", imuTemp);

  // Row 6: Details (small) - v4.0: Arias + CAV + RMS
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(5, 118);
  M5.Lcd.printf("AI:%.4f CAV:%.3f RMS:%.4f K:%.1f", ariasIntensity, cav, vibrationRMS, kurtosis);

  // Row 7: Battery status (v4.1)
  M5.Lcd.setCursor(5, 128);
  M5.Lcd.setTextColor(batteryPercent < 20 ? RED : (batteryCharging ? TFT_CYAN : WHITE));
  M5.Lcd.printf("Bat:%d%% %.2fV%s", batteryPercent, batteryVoltage, batteryCharging ? " CHG" : "");
}

// ===================== BLE FUNCTIONS =====================
void sendBLEData() {
  if (!deviceConnected) return;

  // Send IMU data with all v4.0 features
  // Use explicit strlen to send only the actual JSON string, not null padding
  char imuData[384];
  int imuLen = snprintf(imuData, sizeof(imuData),
    "{\"x\":%.3f,\"y\":%.3f,\"z\":%.3f,\"vib\":%.4f,\"ppv\":%.1f,\"rms\":%.4f,\"freq\":%.1f,\"crest\":%.1f,\"cent\":%.1f,\"kurt\":%.2f,\"stalta\":%.2f,\"arias\":%.6f,\"cav\":%.4f,\"temp\":%.1f,\"dwt1\":%.4f,\"dwt2\":%.4f,\"dwt3\":%.4f}",
    accX, accY, accZ, vibrationMagnitude, vibrationPPV, vibrationRMS,
    dominantFreq, crestFactor, spectralCentroid, kurtosis, staLtaRatio,
    ariasIntensity, cav, imuTemp, dwtEnergy1, dwtEnergy2, dwtEnergy3);
  if (imuLen >= (int)sizeof(imuData)) {
    Serial.printf("BLE WARNING: IMU JSON truncated (%d >= %d)\n", imuLen, (int)sizeof(imuData));
  }
  pIMUChar->setValue((uint8_t*)imuData, strlen(imuData));
  pIMUChar->notify();

  // Send moisture data
  char moistureData[50];
  snprintf(moistureData, sizeof(moistureData),
    "{\"percent\":%d,\"raw\":%d}",
    moisturePercent, rawMoisture);
  pMoistureChar->setValue((uint8_t*)moistureData, strlen(moistureData));
  pMoistureChar->notify();

  // Send alert data with hazard type
  char alertData[150];
  const char* alertLevel = currentAlert == CRITICAL ? "critical" :
                          (currentAlert == WARNING ? "warning" : "safe");
  snprintf(alertData, sizeof(alertData),
    "{\"level\":\"%s\",\"message\":\"%s\",\"type\":\"%s\"}",
    alertLevel, alertMessage.c_str(), hazardType.c_str());
  pAlertChar->setValue((uint8_t*)alertData, strlen(alertData));
  pAlertChar->notify();

  // Send battery data (v4.1)
  char batteryData[80];
  snprintf(batteryData, sizeof(batteryData),
    "{\"voltage\":%.2f,\"percent\":%d,\"charging\":%s}",
    batteryVoltage, batteryPercent, batteryCharging ? "true" : "false");
  pBatteryChar->setValue((uint8_t*)batteryData, strlen(batteryData));
  pBatteryChar->notify();

  // Send FFT magnitude bins as binary uint16 (v4.2)
  // 64 bins covering 0-100Hz, each bin scaled to uint16 range
  {
    uint8_t fftBuf[130]; // 1 byte header + 64 * 2 bytes
    fftBuf[0] = 64; // number of bins
    fftBuf[1] = 0;  // reserved
    double maxMag = 0.001; // prevent divide by zero
    for (int i = 0; i < 64; i++) {
      if (vReal[i] > maxMag) maxMag = vReal[i];
    }
    for (int i = 0; i < 64; i++) {
      uint16_t val = (uint16_t)((vReal[i] / maxMag) * 65535.0);
      fftBuf[2 + i * 2] = val & 0xFF;
      fftBuf[2 + i * 2 + 1] = (val >> 8) & 0xFF;
    }
    pFFTChar->setValue(fftBuf, 130);
    pFFTChar->notify();
  }
}

void testAlert() {
  Serial.println("Test alert triggered!");
  M5.Speaker.tone(1000, 300);

  if (deviceConnected) {
    char alertData[150];
    snprintf(alertData, sizeof(alertData),
      "{\"level\":\"warning\",\"message\":\"Test alert from button\",\"type\":\"test\"}");
    pAlertChar->setValue((uint8_t*)alertData, strlen(alertData));
    pAlertChar->notify();
  }
}
