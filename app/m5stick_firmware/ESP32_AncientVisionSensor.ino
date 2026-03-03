/*
 * AncientVision Trench Safety Monitor
 * For Generic ESP32 Development Board with MPU6050 IMU + Soil Moisture Sensor
 *
 * Features:
 * - MPU6050 IMU accelerometer for vibration/earthquake detection
 * - Soil moisture sensor reading
 * - Bluetooth Low Energy (BLE) for app communication
 * - LED indicators for status
 *
 * Wiring:
 * ┌─────────────────────────────────────────────────────────┐
 * │ ESP32           MPU6050 (I2C)                           │
 * │ ─────           ──────────────                          │
 * │ 3.3V      →     VCC                                     │
 * │ GND       →     GND                                     │
 * │ GPIO 21   →     SDA                                     │
 * │ GPIO 22   →     SCL                                     │
 * │                                                         │
 * │ ESP32           Soil Moisture Sensor                    │
 * │ ─────           ────────────────────                    │
 * │ 3.3V      →     VCC                                     │
 * │ GND       →     GND                                     │
 * │ GPIO 34   →     Signal (Analog Out)                     │
 * │                                                         │
 * │ ESP32           Status LED (optional)                   │
 * │ ─────           ─────────────────────                   │
 * │ GPIO 2    →     LED+ (built-in on most boards)          │
 * └─────────────────────────────────────────────────────────┘
 */

#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ===================== CONFIGURATION =====================
// Soil Moisture Thresholds (safe range: 30-60%)
const int MOISTURE_MIN_SAFE = 30;
const int MOISTURE_MAX_SAFE = 60;

// Vibration Thresholds (in g)
const float VIBRATION_WARNING = 0.3;   // Warning level
const float VIBRATION_CRITICAL = 0.8;  // Critical - possible earthquake/collapse

// Pin Definitions
const int MOISTURE_PIN = 34;  // ADC1 channel (GPIO 34, 35, 36, 39 work best)
const int LED_PIN = 2;        // Built-in LED on most ESP32 boards
const int SDA_PIN = 21;       // I2C SDA
const int SCL_PIN = 22;       // I2C SCL

// Calibration values for soil moisture sensor
// Adjust these based on your specific sensor
const int MOISTURE_AIR = 4095;    // Value when sensor is in air (dry) - ESP32 12-bit ADC
const int MOISTURE_WATER = 1500;  // Value when sensor is in water (wet)

// MPU6050 I2C Address
const int MPU6050_ADDR = 0x68;

// BLE UUIDs (must match the Flutter app)
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_IMU_UUID       "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CHAR_MOISTURE_UUID  "beb5483e-36e1-4688-b7f5-ea07361b26a9"
#define CHAR_ALERT_UUID     "beb5483e-36e1-4688-b7f5-ea07361b26aa"

// ===================== GLOBALS =====================
BLEServer* pServer = NULL;
BLECharacteristic* pIMUChar = NULL;
BLECharacteristic* pMoistureChar = NULL;
BLECharacteristic* pAlertChar = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Sensor data
float accX = 0, accY = 0, accZ = 0;
float gyroX = 0, gyroY = 0, gyroZ = 0;
float vibrationMagnitude = 0;
int moisturePercent = 0;
int rawMoisture = 0;

// Alert states
enum AlertState { SAFE, WARNING, CRITICAL };
AlertState currentAlert = SAFE;
String alertMessage = "";

// Timing
unsigned long lastSensorRead = 0;
unsigned long lastBLESend = 0;
unsigned long lastLEDBlink = 0;
const int SENSOR_INTERVAL = 100;  // Read sensors every 100ms
const int BLE_INTERVAL = 500;     // Send BLE every 500ms

// MPU6050 calibration offsets
float accXOffset = 0, accYOffset = 0, accZOffset = 0;

// ===================== BLE CALLBACKS =====================
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println("Device connected!");
      digitalWrite(LED_PIN, HIGH);
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("Device disconnected!");
      digitalWrite(LED_PIN, LOW);
    }
};

// ===================== SETUP =====================
void setup() {
  Serial.begin(115200);
  Serial.println("\n========================================");
  Serial.println("AncientVision Trench Safety Monitor");
  Serial.println("ESP32 + MPU6050 + Soil Moisture");
  Serial.println("========================================\n");

  // Initialize LED
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  // Initialize I2C for MPU6050
  Wire.begin(SDA_PIN, SCL_PIN);

  // Initialize MPU6050
  if (!initMPU6050()) {
    Serial.println("ERROR: MPU6050 not found! Check wiring.");
    // Blink LED rapidly to indicate error
    while (true) {
      digitalWrite(LED_PIN, HIGH);
      delay(100);
      digitalWrite(LED_PIN, LOW);
      delay(100);
    }
  }
  Serial.println("MPU6050 initialized successfully");

  // Calibrate MPU6050 (keep device still during startup)
  Serial.println("Calibrating IMU - keep device still...");
  calibrateMPU6050();
  Serial.println("Calibration complete!");

  // Initialize moisture sensor pin
  pinMode(MOISTURE_PIN, INPUT);
  Serial.println("Moisture sensor initialized");

  // Initialize BLE
  setupBLE();

  Serial.println("\nSetup complete! Ready for connections...\n");
}

// ===================== MPU6050 FUNCTIONS =====================
bool initMPU6050() {
  // Wake up MPU6050
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(0x6B);  // PWR_MGMT_1 register
  Wire.write(0x00);  // Wake up
  if (Wire.endTransmission(true) != 0) {
    return false;
  }

  // Configure accelerometer range to ±2g
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(0x1C);  // ACCEL_CONFIG register
  Wire.write(0x00);  // ±2g range
  Wire.endTransmission(true);

  // Configure gyroscope range to ±250°/s
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(0x1B);  // GYRO_CONFIG register
  Wire.write(0x00);  // ±250°/s range
  Wire.endTransmission(true);

  delay(100);
  return true;
}

void calibrateMPU6050() {
  const int numSamples = 100;
  float sumX = 0, sumY = 0, sumZ = 0;

  for (int i = 0; i < numSamples; i++) {
    readMPU6050Raw();
    sumX += accX;
    sumY += accY;
    sumZ += accZ;
    delay(10);
  }

  accXOffset = sumX / numSamples;
  accYOffset = sumY / numSamples;
  accZOffset = (sumZ / numSamples) - 1.0;  // Subtract 1g (gravity)

  Serial.printf("Calibration offsets: X=%.3f Y=%.3f Z=%.3f\n",
                accXOffset, accYOffset, accZOffset);
}

void readMPU6050Raw() {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(0x3B);  // Starting register for accelerometer data
  Wire.endTransmission(false);
  Wire.requestFrom(MPU6050_ADDR, 14, true);

  // Read accelerometer data (raw 16-bit values)
  int16_t rawAccX = Wire.read() << 8 | Wire.read();
  int16_t rawAccY = Wire.read() << 8 | Wire.read();
  int16_t rawAccZ = Wire.read() << 8 | Wire.read();

  // Skip temperature
  Wire.read(); Wire.read();

  // Read gyroscope data
  int16_t rawGyroX = Wire.read() << 8 | Wire.read();
  int16_t rawGyroY = Wire.read() << 8 | Wire.read();
  int16_t rawGyroZ = Wire.read() << 8 | Wire.read();

  // Convert to g (±2g range = 16384 LSB/g)
  accX = rawAccX / 16384.0;
  accY = rawAccY / 16384.0;
  accZ = rawAccZ / 16384.0;

  // Convert to degrees/second (±250°/s range = 131 LSB/°/s)
  gyroX = rawGyroX / 131.0;
  gyroY = rawGyroY / 131.0;
  gyroZ = rawGyroZ / 131.0;
}

void readMPU6050() {
  readMPU6050Raw();

  // Apply calibration offsets
  accX -= accXOffset;
  accY -= accYOffset;
  accZ -= accZOffset;
}

// ===================== BLE SETUP =====================
void setupBLE() {
  Serial.println("Starting BLE...");

  BLEDevice::init("AncientVision-Sensor");

  // Create BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // Create BLE Service
  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Create BLE Characteristics
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

  // Start service
  pService->start();

  // Start advertising
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE ready - device name: AncientVision-Sensor");
}

// ===================== MAIN LOOP =====================
void loop() {
  unsigned long currentMillis = millis();

  // Read sensors at regular interval
  if (currentMillis - lastSensorRead >= SENSOR_INTERVAL) {
    lastSensorRead = currentMillis;
    readSensors();
    checkAlerts();
    updateLED();
    printStatus();
  }

  // Send BLE data at regular interval
  if (currentMillis - lastBLESend >= BLE_INTERVAL) {
    lastBLESend = currentMillis;
    sendBLEData();
  }

  // Handle BLE connection changes
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println("Restart advertising");
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }
}

// ===================== SENSOR FUNCTIONS =====================
void readSensors() {
  // Read IMU
  readMPU6050();

  // Calculate vibration magnitude (deviation from rest)
  float totalAccel = sqrt(accX*accX + accY*accY + accZ*accZ);
  vibrationMagnitude = abs(totalAccel - 1.0);  // Deviation from 1g

  // Read moisture sensor
  rawMoisture = analogRead(MOISTURE_PIN);

  // Convert to percentage (higher ADC value = drier soil)
  moisturePercent = map(rawMoisture, MOISTURE_AIR, MOISTURE_WATER, 0, 100);
  moisturePercent = constrain(moisturePercent, 0, 100);
}

void checkAlerts() {
  AlertState newAlert = SAFE;
  alertMessage = "";

  // Check vibration
  if (vibrationMagnitude > VIBRATION_CRITICAL) {
    newAlert = CRITICAL;
    alertMessage = "EARTHQUAKE DETECTED!";
  } else if (vibrationMagnitude > VIBRATION_WARNING) {
    newAlert = WARNING;
    alertMessage = "High vibration";
  }

  // Check moisture
  if (moisturePercent < MOISTURE_MIN_SAFE) {
    if (newAlert < WARNING) {
      newAlert = WARNING;
      alertMessage = "Soil too dry";
    }
  } else if (moisturePercent > MOISTURE_MAX_SAFE) {
    if (newAlert < CRITICAL) {
      newAlert = CRITICAL;
      alertMessage = "Soil too wet - collapse risk!";
    }
  }

  currentAlert = newAlert;
}

void updateLED() {
  static unsigned long lastBlink = 0;
  static bool ledState = false;

  switch (currentAlert) {
    case CRITICAL:
      // Fast blink for critical
      if (millis() - lastBlink > 100) {
        lastBlink = millis();
        ledState = !ledState;
        digitalWrite(LED_PIN, ledState);
      }
      break;
    case WARNING:
      // Slow blink for warning
      if (millis() - lastBlink > 500) {
        lastBlink = millis();
        ledState = !ledState;
        digitalWrite(LED_PIN, ledState);
      }
      break;
    default:
      // Solid on if connected, off if not
      digitalWrite(LED_PIN, deviceConnected ? HIGH : LOW);
      break;
  }
}

void printStatus() {
  static unsigned long lastPrint = 0;
  if (millis() - lastPrint < 1000) return;  // Print once per second
  lastPrint = millis();

  Serial.printf("IMU: X=%.2f Y=%.2f Z=%.2f | Vib=%.3fg | Moisture=%d%% (raw=%d)",
                accX, accY, accZ, vibrationMagnitude, moisturePercent, rawMoisture);

  if (currentAlert == CRITICAL) {
    Serial.print(" | !! CRITICAL !!");
  } else if (currentAlert == WARNING) {
    Serial.print(" | ! Warning !");
  }

  Serial.printf(" | BLE: %s\n", deviceConnected ? "Connected" : "Waiting...");
}

// ===================== BLE FUNCTIONS =====================
void sendBLEData() {
  if (!deviceConnected) return;

  // Send IMU data as JSON
  char imuData[100];
  snprintf(imuData, sizeof(imuData),
    "{\"x\":%.3f,\"y\":%.3f,\"z\":%.3f,\"vib\":%.4f}",
    accX, accY, accZ, vibrationMagnitude);
  pIMUChar->setValue(imuData);
  pIMUChar->notify();

  // Send moisture data as JSON
  char moistureData[50];
  snprintf(moistureData, sizeof(moistureData),
    "{\"percent\":%d,\"raw\":%d}",
    moisturePercent, rawMoisture);
  pMoistureChar->setValue(moistureData);
  pMoistureChar->notify();

  // Send alert data as JSON
  char alertData[100];
  const char* alertLevel = currentAlert == CRITICAL ? "critical" :
                          (currentAlert == WARNING ? "warning" : "safe");
  snprintf(alertData, sizeof(alertData),
    "{\"level\":\"%s\",\"message\":\"%s\"}",
    alertLevel, alertMessage.c_str());
  pAlertChar->setValue(alertData);
  pAlertChar->notify();
}
