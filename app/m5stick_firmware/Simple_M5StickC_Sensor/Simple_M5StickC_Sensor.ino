/*
 * AncientVision Trench Safety Monitor - SIMPLE VERSION
 * For M5StickC Plus 2 (using basic ESP32 libraries only)
 *
 * NO SPECIAL LIBRARIES NEEDED - just ESP32 board support!
 */

#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ===================== PIN DEFINITIONS =====================
// M5StickC Plus 2 specific pins
const int SDA_PIN = 21;       // I2C SDA (internal IMU)
const int SCL_PIN = 22;       // I2C SCL (internal IMU)
const int MOISTURE_PIN = 33;  // Grove port GPIO
const int LED_PIN = 19;       // Internal LED (accent LED)
const int BUTTON_A = 37;      // Front button

// MPU6886 I2C Address (M5StickC Plus 2 internal IMU)
const int IMU_ADDR = 0x68;

// ===================== THRESHOLDS =====================
const int MOISTURE_MIN_SAFE = 30;
const int MOISTURE_MAX_SAFE = 60;
const float VIBRATION_WARNING = 0.3;
const float VIBRATION_CRITICAL = 0.8;

// Moisture sensor calibration
const int MOISTURE_AIR = 3500;
const int MOISTURE_WATER = 1500;

// ===================== BLE UUIDs =====================
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

float accX = 0, accY = 0, accZ = 0;
float vibration = 0;
int moisturePercent = 0;
String alertLevel = "safe";
String alertMessage = "";

unsigned long lastSensorRead = 0;
unsigned long lastBLESend = 0;

// ===================== BLE CALLBACKS =====================
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    digitalWrite(LED_PIN, HIGH);
    Serial.println("Connected!");
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    digitalWrite(LED_PIN, LOW);
    Serial.println("Disconnected!");
  }
};

// ===================== SETUP =====================
void setup() {
  Serial.begin(115200);
  Serial.println("\n=== AncientVision Sensor ===");

  pinMode(LED_PIN, OUTPUT);
  pinMode(BUTTON_A, INPUT_PULLUP);
  pinMode(MOISTURE_PIN, INPUT);

  // Init I2C
  Wire.begin(SDA_PIN, SCL_PIN);

  // Init IMU
  initIMU();

  // Init BLE
  setupBLE();

  Serial.println("Ready! Waiting for app...");
}

void initIMU() {
  // Wake up IMU
  Wire.beginTransmission(IMU_ADDR);
  Wire.write(0x6B);
  Wire.write(0x00);
  Wire.endTransmission();

  // Set accelerometer to ±2g
  Wire.beginTransmission(IMU_ADDR);
  Wire.write(0x1C);
  Wire.write(0x00);
  Wire.endTransmission();

  delay(100);
  Serial.println("IMU ready");
}

void setupBLE() {
  BLEDevice::init("AncientVision-Sensor");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pIMUChar = pService->createCharacteristic(CHAR_IMU_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pIMUChar->addDescriptor(new BLE2902());

  pMoistureChar = pService->createCharacteristic(CHAR_MOISTURE_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pMoistureChar->addDescriptor(new BLE2902());

  pAlertChar = pService->createCharacteristic(CHAR_ALERT_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pAlertChar->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->start();

  Serial.println("BLE ready: AncientVision-Sensor");
}

// ===================== LOOP =====================
void loop() {
  unsigned long now = millis();

  // Read sensors every 100ms
  if (now - lastSensorRead >= 100) {
    lastSensorRead = now;
    readSensors();
    checkAlerts();
  }

  // Send BLE data every 500ms
  if (now - lastBLESend >= 500) {
    lastBLESend = now;
    sendBLEData();
    printStatus();
  }

  // Handle reconnection
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }
}

void readSensors() {
  // Read IMU
  Wire.beginTransmission(IMU_ADDR);
  Wire.write(0x3B);
  Wire.endTransmission(false);
  Wire.requestFrom(IMU_ADDR, 6);

  int16_t rawX = Wire.read() << 8 | Wire.read();
  int16_t rawY = Wire.read() << 8 | Wire.read();
  int16_t rawZ = Wire.read() << 8 | Wire.read();

  accX = rawX / 16384.0;
  accY = rawY / 16384.0;
  accZ = rawZ / 16384.0;

  float total = sqrt(accX*accX + accY*accY + accZ*accZ);
  vibration = abs(total - 1.0);

  // Read moisture
  int raw = analogRead(MOISTURE_PIN);
  moisturePercent = map(raw, MOISTURE_AIR, MOISTURE_WATER, 0, 100);
  moisturePercent = constrain(moisturePercent, 0, 100);
}

void checkAlerts() {
  alertLevel = "safe";
  alertMessage = "";

  if (vibration > VIBRATION_CRITICAL) {
    alertLevel = "critical";
    alertMessage = "EARTHQUAKE!";
  } else if (vibration > VIBRATION_WARNING) {
    alertLevel = "warning";
    alertMessage = "High vibration";
  }

  if (moisturePercent > MOISTURE_MAX_SAFE) {
    alertLevel = "critical";
    alertMessage = "Soil too wet!";
  } else if (moisturePercent < MOISTURE_MIN_SAFE) {
    if (alertLevel == "safe") {
      alertLevel = "warning";
      alertMessage = "Soil too dry";
    }
  }
}

void sendBLEData() {
  if (!deviceConnected) return;

  char buf[100];

  snprintf(buf, sizeof(buf), "{\"x\":%.3f,\"y\":%.3f,\"z\":%.3f,\"vib\":%.4f}",
           accX, accY, accZ, vibration);
  pIMUChar->setValue(buf);
  pIMUChar->notify();

  snprintf(buf, sizeof(buf), "{\"percent\":%d,\"raw\":%d}",
           moisturePercent, analogRead(MOISTURE_PIN));
  pMoistureChar->setValue(buf);
  pMoistureChar->notify();

  snprintf(buf, sizeof(buf), "{\"level\":\"%s\",\"message\":\"%s\"}",
           alertLevel.c_str(), alertMessage.c_str());
  pAlertChar->setValue(buf);
  pAlertChar->notify();
}

void printStatus() {
  Serial.printf("Vib: %.3fg | Moisture: %d%% | BLE: %s\n",
                vibration, moisturePercent,
                deviceConnected ? "Connected" : "Waiting...");
}
