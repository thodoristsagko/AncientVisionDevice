# AncientVision — Quick Start Guide

**For the archaeologist on Paros. Follow these steps to get up and running.**

---

## Step 1: Open the App

Launch **AncientVision** from your app drawer. You will land on the **Home** dashboard.

## Step 2: Turn On the Sensor

Press the power button on the **M5StickC Plus 2** device. Wait until the screen shows "Sensor Ready".

## Step 3: Connect via Bluetooth

Go to the **Safety** tab (shield icon at the bottom). Tap **"Scan for Devices"** and select **"AncientVision-Sensor"**. Wait a few seconds for the connection — you will see live data appear.

## Step 4: Place the Sensor at the Excavation Site

Put the M5StickC near the area you are working on. The sensor measures **ground vibration** and **soil moisture** in real time. You can walk away — data streams over Bluetooth.

## Step 5: Monitor Safety While You Work

Switch to any tab — the Bluetooth connection stays alive in the background. If vibration or moisture reaches dangerous levels, the app will:
- Show a **full-screen red alert** on any tab
- Play an **alarm sound**
- **Speak the warning** out loud (text-to-speech)
- **Vibrate your phone**

## Step 6: Understand the Safety Readings

| Sensor | Safe | Warning | Critical |
|--------|------|---------|----------|
| **Vibration (PPV)** | < 3 mm/s | 3–8 mm/s | > 8 mm/s |
| **Soil Moisture** | 30–60% | 60–80% | > 80% (collapse risk) |

The app also runs **ML anomaly detection** — it will warn you about unusual vibration patterns even if they haven't crossed a threshold yet.

## Step 7: Record a Finding

Go to the **Home** tab and tap **"Manual Entry"**. Fill in at least:
- **Name** (e.g., "Bronze Coin")
- **Type** (e.g., "Numismatic")
- **Site** (e.g., "Paros — Sector B")
- **Date**

Add a photo if you want. Tap **"Save Finding"**.

## Step 8: Capture a 3D Model (Optional)

Go to the **Tools** tab → **3D Reconstruction**. Place the artifact on a plain background and take **12–16 photos** from all angles. The app guides you through each position. Then tap **"Reconstruct 3D Model"** and wait 1–3 minutes.

## Step 9: Browse Your Findings

Go to the **Findings** tab to see all recorded artifacts in a gallery or on a map. Tap any card to see its full details.

## Step 10: Export a Report

Go to **Tools** → **PDF Reports**. Select the findings you want and tap **"Generate PDF"**. You can share the PDF directly via email or messaging.

## Step 11: Mute Alerts (When Needed)

The **speaker icon** in the bottom navigation bar lets you mute/unmute all alert sounds, alarms, and voice warnings across the entire app. Useful during meetings or phone calls.

## Step 12: Check Sensor Battery

The Safety tab shows the M5StickC battery level (voltage and percentage). Charge it via USB-C when it drops below 20%.

## Step 13: Test the Alert System

Press **Button A** on the M5StickC to send a test alert. Your phone should show a full-screen warning, play a sound, and vibrate. This confirms everything is working before you start excavating.

## Step 14: End of Day

Power off the M5StickC (hold the power button). Your findings are saved locally on the phone. When you have Wi-Fi, open the app and sync your data.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Sensor won't connect | Make sure Bluetooth is on. Restart the M5StickC. Move closer. |
| No vibration readings | Wait 10 seconds after connecting — the sensor calibrates on startup. |
| 3D reconstruction fails | Take more photos (min 8), improve lighting, avoid shiny objects. |
| App crashes | Clear cache (Settings → Apps → AncientVision → Clear Cache) and reopen. |

---

*AncientVision — Protecting heritage with technology. FLL Submerged 2025.*
