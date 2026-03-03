# ESP32 - AncientVision Trench Safety Sensor

Generic ESP32 version using MPU6050 IMU module.

## Hardware Required
- ESP32 Development Board (DevKit, NodeMCU-32S, etc.)
- MPU6050 IMU Module (accelerometer + gyroscope)
- Capacitive Soil Moisture Sensor (analog output)
- Jumper wires
- Breadboard (optional)

## Wiring Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   ESP32 DevKit              MPU6050 IMU                      │
│   ────────────              ───────────                      │
│                                                              │
│       3.3V  ──────────────→  VCC                             │
│       GND   ──────────────→  GND                             │
│       GPIO 21 (SDA) ──────→  SDA                             │
│       GPIO 22 (SCL) ──────→  SCL                             │
│                                                              │
│   ESP32 DevKit              Soil Moisture Sensor             │
│   ────────────              ────────────────────             │
│                                                              │
│       3.3V  ──────────────→  VCC                             │
│       GND   ──────────────→  GND                             │
│       GPIO 34 ────────────→  Signal (Analog Out)             │
│                                                              │
│   Note: GPIO 34/35/36/39 are ADC1 pins (best for analog)     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Visual Wiring (ASCII Art)

```
                    ┌─────────────┐
                    │   MPU6050   │
                    │             │
    ESP32           │  VCC ──┐    │
   ┌──────┐         │  GND ──┼─┐  │
   │      │         │  SCL ──┼─┼─┐│
   │ 3.3V ├─────────┤  SDA ──┼─┼─┼┤
   │ GND  ├─────────┼────────┘ │ ││
   │ G22  ├─────────┼──────────┘ ││
   │ G21  ├─────────┼────────────┘│
   │      │         └─────────────┘
   │      │
   │      │         ┌─────────────────┐
   │      │         │  Soil Moisture  │
   │ 3.3V ├─────────┤  VCC            │
   │ GND  ├─────────┤  GND            │
   │ G34  ├─────────┤  Signal (AO)    │
   │      │         └─────────────────┘
   │      │
   │  LED ├── (Built-in GPIO 2)
   └──────┘
```

## Software Setup

### 1. Install Arduino IDE
Download from: https://www.arduino.cc/en/software

### 2. Install ESP32 Board Support
1. Open Arduino IDE
2. Go to **File → Preferences**
3. Add this URL to "Additional Board Manager URLs":
   ```
   https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
   ```
4. Go to **Tools → Board → Boards Manager**
5. Search for "esp32" and install **esp32 by Espressif Systems**
6. Select your board: **Tools → Board → ESP32 Arduino → ESP32 Dev Module**

### 3. Configure Board Settings
In **Tools** menu, set:
- Board: "ESP32 Dev Module"
- Upload Speed: "921600"
- CPU Frequency: "240MHz (WiFi/BT)"
- Flash Frequency: "80MHz"
- Flash Mode: "QIO"
- Flash Size: "4MB (32Mb)"
- Partition Scheme: "Default 4MB with spiffs"
- PSRAM: "Disabled"

### 4. Upload the Firmware
1. Connect ESP32 via USB
2. Select the correct port: **Tools → Port → COMx**
3. Open `ESP32_AncientVisionSensor.ino`
4. Click **Upload** (→ arrow button)
5. If upload fails, hold **BOOT** button while uploading

## Calibration

### Soil Moisture Sensor Calibration
Edit these values in the code:

```cpp
const int MOISTURE_AIR = 4095;    // Value in air (dry) - ESP32 has 12-bit ADC
const int MOISTURE_WATER = 1500;  // Value in water (wet)
```

To calibrate:
1. Open Serial Monitor (115200 baud)
2. Note raw value when sensor is in air → `MOISTURE_AIR`
3. Note raw value when sensor is in water → `MOISTURE_WATER`
4. Update code and re-upload

### IMU Auto-Calibration
The MPU6050 auto-calibrates on startup:
- **Keep the device completely still** for 2-3 seconds after power on
- The LED will stay off during calibration
- Calibration offsets are shown in Serial Monitor

## LED Indicators

| Pattern | Meaning |
|---------|---------|
| Solid ON | Connected to app, all safe |
| Slow blink (0.5s) | Warning - check values |
| Fast blink (0.1s) | Critical alert! |
| OFF | Not connected / Calibrating |

## Serial Monitor Output

Connect at 115200 baud to see:
```
IMU: X=0.01 Y=-0.02 Z=0.98 | Vib=0.003g | Moisture=45% (raw=2847) | BLE: Connected
```

## Troubleshooting

### "MPU6050 not found"
- Check I2C wiring (SDA→21, SCL→22)
- Verify 3.3V power to MPU6050
- Some modules have different I2C address (try 0x69)

### Upload fails
- Hold BOOT button while uploading
- Try lower upload speed (115200)
- Check USB cable (data cable, not charge-only)

### Wrong moisture readings
- Use GPIO 34, 35, 36, or 39 (ADC1 pins)
- ADC2 pins don't work with WiFi/BLE enabled
- Recalibrate with your specific sensor

### Vibration always shows high
- Keep device still during startup calibration
- Check MPU6050 mounting (secure, no vibration)

## Pin Reference

| Function | GPIO | Notes |
|----------|------|-------|
| I2C SDA | 21 | MPU6050 data |
| I2C SCL | 22 | MPU6050 clock |
| Moisture | 34 | ADC1 only (34/35/36/39) |
| LED | 2 | Built-in on most boards |

## Thresholds

| Sensor | Safe | Warning | Critical |
|--------|------|---------|----------|
| Soil Moisture | 30-60% | <30% or >60% | >60% |
| Vibration | <0.3g | 0.3-0.8g | >0.8g |
