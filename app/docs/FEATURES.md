# AncientVision Features Guide

Complete documentation of all features and capabilities.

---

## Table of Contents

1. [Authentication](#1-authentication)
2. [Dashboard](#2-dashboard)
3. [Findings Management](#3-findings-management)
4. [3D Photogrammetry](#4-3d-photogrammetry)
5. [Manual Entry Form](#5-manual-entry-form)
6. [Trench Safety Monitoring](#6-trench-safety-monitoring)
7. [Export & Reports](#7-export--reports)
8. [Tools Menu](#8-tools-menu)
9. [Analytics Dashboard](#9-analytics-dashboard)
10. [Field Journal](#10-field-journal)
11. [Offline Support](#11-offline-support)
12. [Settings & Customization](#12-settings--customization)
13. [Quick Capture](#13-quick-capture)
14. [Data Validation](#14-data-validation)

---

## 1. Authentication

### Login Methods
- **Email/Password** - Traditional registration with full name
- **Google Sign-In** - One-tap OAuth authentication

### Security Features
- Firebase Authentication backend
- Secure token management
- Activity logging to Firestore
- Session persistence

### User Profile
- Display name
- Email address
- Profile photo (Google accounts)
- Creation date
- Last login timestamp

---

## 2. Dashboard

The home screen provides a complete overview of your archaeological data.

### Statistics Cards
| Card | Description |
|------|-------------|
| Total Findings | Count of all recorded artifacts |
| Today's Finds | Findings added in the last 24 hours |
| By Type | Breakdown by artifact type |
| By Site | Distribution across excavation sites |

### Recent Activity
- Last 5 findings with thumbnails
- Quick tap to view details
- Timestamp and type indicators

### Quick Actions
- **Manual Entry** - Jump to recording form
- **3D Capture** - Start photogrammetry
- **Export PDF** - Generate reports
- **View All** - Browse findings gallery

### Sync Status
- Shows count of pending offline uploads
- "Sync Now" button when online
- Visual indicator during sync

---

## 3. Findings Management

### Gallery View
- Grid layout with thumbnails
- Search by name, type, or site
- Filter by date range
- Sort by date, name, or type

### Map View
- Interactive map with markers
- Cluster view for dense areas
- Tap marker for finding preview
- GPS coordinates display

### Finding Details
Expandable sections showing:

**Basic Information**
- Name, type, site, date
- Description and notes
- GPS coordinates

**Artifact Measurements**
- Dimensions (L x W x H in mm)
- Weight (grams)
- Material classification

**Archaeological Context**
- Find number (catalog ID)
- Excavation unit
- Stratigraphic layer
- Depth below surface
- Depth below datum

**Scientific Data**
- Dating method
- Cultural period
- Soil type
- Munsell color code
- Preservation condition

**Media**
- Photo gallery (swipeable)
- 3D model viewer (if available)

---

## 4. 3D Photogrammetry

### Hero Feature
The centerpiece of AncientVision - real Structure from Motion 3D reconstruction.

### Capture System

#### 16 Optimized Angles
| Ring | Positions | Description |
|------|-----------|-------------|
| Ring 1 | 8 | Eye level, every 45° |
| Ring 2 | 4 | 45° elevation, every 90° |
| Top | 2 | 80° and 70° from above |
| Detail | 2 | Close-up shots |

#### Capture Modes
- **Photo Mode** - Individual captures with guidance
- **Video Mode** - Continuous recording with frame extraction
- **Tutorial Mode** - Step-by-step for beginners

### AR-Like Guidance
Real-time sensor feedback during capture:
- Device tilt indicators (X/Y axes)
- Compass heading display
- Rotation speed warning
- Visual angle markers

### Quality Analysis
Each photo is analyzed for:
- **Sharpness** - Laplacian variance (target: >500)
- **Exposure** - Brightness histogram
- **Blur** - Motion blur detection
- **Noise** - Estimation of sensor noise

### 3D Reconstruction

#### Process Steps
1. Load & validate images
2. Extract Harris corner features
3. Match features between images
4. Estimate Essential Matrix (8-point algorithm)
5. RANSAC outlier rejection
6. Recover camera poses
7. Triangulate 3D points
8. Bundle adjustment optimization
9. Generate point cloud
10. Export results

#### Algorithms Used
| Algorithm | Purpose |
|-----------|---------|
| Harris Corner | Feature detection |
| Cross-Correlation | Feature matching |
| 8-Point Algorithm | Essential matrix |
| RANSAC | Outlier rejection |
| Triangulation | 3D point computation |
| Bundle Adjustment | Refinement |

#### Success Metrics
- **Reprojection Error** - Target: <2.0 pixels
- **Coverage** - Target: >60%
- **Point Count** - Typical: 500-5000 points
- **Success Rate** - 85-95% with proper capture

### Processing Methods

#### Cloud Processing (Recommended)
Uses **OpenScan Cloud API** - completely FREE service.

| Aspect | Details |
|--------|---------|
| Quality | Professional dense mesh with textures |
| Time | 5-15 minutes |
| Requires | Internet connection |
| Output | GLB/OBJ with textures |
| Best for | Final documentation |

#### On-Device Processing
Quick preview using on-device SfM algorithms.

| Aspect | Details |
|--------|---------|
| Quality | Sparse point cloud |
| Time | 1-3 minutes |
| Requires | Nothing (works offline) |
| Output | PLY point cloud |
| Best for | Quick preview, field verification |

### Handling Difficult Objects

Some objects are challenging for ANY photogrammetry system due to physics limitations.

#### Problem Objects
| Object Type | Issue | Difficulty |
|-------------|-------|------------|
| **Black objects** | Low contrast, few features | High |
| **Shiny/metallic** | Specular reflections move | High |
| **Smooth surfaces** | No texture to match | High |
| **Transparent** | Light passes through | Very High |
| **Uniform color** | No distinct features | Medium |

#### Solutions for Difficult Objects

**Temporary Texture Methods:**
| Method | How to Apply | Removal |
|--------|--------------|---------|
| Chalk spray | Light mist coating | Brush off |
| Talcum powder | Dust with brush | Blow off |
| Flour | Light dusting | Wash off |
| Developer spray | Forensic type | Evaporates |

**Lighting Techniques:**
- Use diffused lighting (cloudy day ideal)
- Avoid direct sunlight (creates harsh shadows)
- Cross-polarized lighting reduces reflections
- Ring lights provide even illumination

**Camera Settings:**
- Reduce exposure for shiny objects
- Increase ISO in low-contrast situations
- Use HDR mode for difficult lighting

#### Cloud vs On-Device for Difficult Objects

| Aspect | Cloud | On-Device |
|--------|-------|-----------|
| Algorithm quality | Better (COLMAP-based) | Basic SfM |
| Feature detection | More robust | Limited |
| Gap filling | AI-enhanced | None |
| **Still struggles with** | Black + smooth objects | Same |

**Bottom line:** Cloud processing gives better results on difficult objects, but won't magically solve physics limitations. For truly challenging objects, use temporary texture spray.

### 3D Viewer
Interactive visualization with:
- Touch rotation (X/Y axes)
- Pinch zoom
- Two-finger pan
- Auto-rotation toggle
- Point size adjustment
- Color/grayscale toggle
- Statistics overlay

### Export Options
- **PLY Format** - Point cloud with colors
- **Direct Share** - Via system share dialog

### Workflow Integration
After reconstruction:
1. "View 3D Model" - Interactive viewer
2. "Complete Form" - Continue to manual entry
3. 3D data automatically saved with finding

---

## 5. Manual Entry Form

Comprehensive archaeological documentation form with 25+ fields.

### Basic Information
| Field | Description | Example |
|-------|-------------|---------|
| Name | Artifact identifier | "Bronze Fibula" |
| Type | Artifact category | "Metal Object" |
| Site | Excavation site name | "Amphipolis Tomb D" |
| Date | Discovery date | "2024-03-15" |
| Description | Detailed notes | Free text |

### Location Data
| Field | Description |
|-------|-------------|
| Latitude | GPS north/south |
| Longitude | GPS east/west |
| GPS Capture | Auto-fill from device |

### Archaeological Context
| Field | Description | Example |
|-------|-------------|---------|
| Find Number | Catalog/accession ID | "2024-FLD-001" |
| Excavation Unit | Grid square/trench | "A4", "Trench 2" |
| Stratigraphic Layer | Context number | "Layer 5" |
| Depth (Surface) | Meters below surface | "1.25" |
| Depth (Datum) | Meters below datum | "2.50" |

### Physical Properties
| Field | Unit | Range |
|-------|------|-------|
| Length | mm | 0-10000 |
| Width | mm | 0-10000 |
| Height | mm | 0-10000 |
| Weight | grams | 0-100000 |

### Classification
| Field | Options |
|-------|---------|
| Material | Terracotta, Bronze, Iron, Gold, Silver, Limestone, Marble, Glass, Bone, Wood, Textile, Other |
| Condition | Excellent, Good, Fair, Poor, Fragmentary |
| Dating Method | Stratigraphy, Typology, C14, TL/OSL, Dendrochronology, Numismatic, Other |
| Cultural Period | Neolithic, Bronze Age, Iron Age, Classical, Hellenistic, Roman, Byzantine, Medieval, Modern |

### Soil Information
| Field | Description |
|-------|-------------|
| Soil Type | Sandy loam, Clay, Silt, etc. |
| Munsell Color | Standardized soil color code |

### Additional Data
| Field | Description |
|-------|-------------|
| Associated Finds | Related artifact IDs |
| Field Notes | Excavation observations |
| Excavator Name | Person who discovered |
| Weathering Degree | Surface degradation level |

### Photo Attachment
- Capture from camera
- Select from gallery
- Multiple photos supported
- Auto-compression (10x smaller)

### Form Features
- **Auto-Save** - Drafts saved every 2 seconds
- **Draft Recovery** - Resume incomplete forms
- **Validation** - Required field checking
- **Smart Suggestions** - Based on previous entries

---

## 6. Trench Safety Monitoring v4.0

### Hardware Integration
Connects to M5StickC Plus 2 microcontroller via Bluetooth Low Energy (BLE).

### Advanced Seismic Analysis (NEW in v4.0)

#### Arias Intensity
Cumulative seismic energy metric (π/2g·∫a²dt):
- Auto-resets every 60 seconds
- Quantifies total earthquake energy delivered to structure
- Used in seismic building codes worldwide

#### CAV (Cumulative Absolute Velocity)
- EPRI threshold: 0.16 g·s for structural damage
- Industry standard for nuclear facility seismic safety
- Color-coded warning levels in app UI

#### 3-Level Haar DWT (Discrete Wavelet Transform)
On-device frequency band decomposition:
- D1: 50-100 Hz (high-frequency machinery)
- D2: 25-50 Hz (mid-frequency structural)
- D3: 12-25 Hz (low-frequency seismic)
- Visualized as colored bars in app

#### IMU Temperature
- MPU6886 die temperature reading
- Thermal bias compensation: 0.0005g/°C applied to acceleration
- Prevents false alarms from temperature drift

#### Recursive STA/LTA
- EMA-based implementation saves 8KB RAM vs. v3.0 circular buffers
- Standard seismology trigger algorithm
- Ratio > 4.0 indicates seismic event

### Sensors Monitored

#### Vibration (IMU Accelerometer)
| Value | Status | Meaning |
|-------|--------|---------|
| <0.3g | Stable | Normal conditions |
| 0.3-0.8g | Warning | Ground movement detected |
| >0.8g | Critical | Earthquake/collapse risk |

#### Soil Moisture (Capacitive Sensor)
| Range | Status | Meaning |
|-------|--------|---------|
| 30-60% | Safe | Optimal range |
| <30% | Warning | Soil too dry, cracking risk |
| >60% | Critical | Soil too wet, collapse risk |

### Alert System
- **Full-screen alerts** appear on ALL tabs (not just Safety) when critical thresholds are exceeded
- **Push notifications** fire even when on other screens
- **Haptic feedback** (phone vibration) on alerts
- **Voice alerts** via text-to-speech announce the danger
- **Alarm sound** plays on critical alerts
- **Global mute button** in bottom navigation bar controls all alert sounds across the entire app

### Display Features v4.0
- **Live Values** - Real-time vibration and moisture readings
- **Status Indicators** - Color-coded safety levels (green/orange/red)
- **History Graph** - Live sensor trends (last 30 data points)
- **Battery Level** - ESP device battery shown on M5StickC screen
- **NEW: Seismic Metrics Row** - Arias Intensity, CAV (with EPRI thresholds), Temperature
- **NEW: DWT Visualization** - 3 frequency band bars (D1/D2/D3) with amplitude colors
- **Conditional Rendering** - v4.0 features only show when v4.0 firmware detected

### Rule-Based Anomaly Fallback (v4.0)
When the TFLite ML model is unavailable or inference fails, a rule-based scoring engine ensures anomaly detection is **never disabled**:

| Feature | Threshold Basis | Weight |
|---------|----------------|--------|
| PPV | DIN 4150-3 heritage limits (0.3/3.0/10.0 mm/s) | 30% |
| STA/LTA | Allen (1978) seismic trigger (>4.0) | 20% |
| CAV | EPRI damage threshold (0.16 g-s) | 15% |
| Crest Factor | ISO 10816 impact detection (>5.0) | 10% |
| Kurtosis | Impulsive event detection (>3.0 excess) | 10% |
| Seismic Freq | Low-frequency concern (0.5-10 Hz + PPV>1.0) | 10% |
| RMS | Sustained vibration energy (>0.5 g) | 5% |

### Low Power Mode (v4.0)
Activated by holding the M5 button for 3 seconds on the device:
- BLE rate reduced from 2Hz to 0.5Hz
- Display refresh reduced from 4Hz to 1Hz
- LCD brightness dimmed to 20%
- **Safety-critical auto-escalation**: When PPV > 0.3 mm/s, automatically runs full DSP (FFT+DWT+kurtosis) so all frequency-dependent hazard rules still fire
- Audio feedback: low tone entering, high tone exiting

### Connection Management
- **Auto-scan** - Automatically finds nearby AncientVision-Sensor devices
- **Persistent connection** - BLE stays connected when switching tabs (IndexedStack)
- **Auto-reconnect** - Exponential backoff reconnection on signal loss (up to 10 attempts)
- **Keep-alive monitor** - 3-second polling for faster disconnect detection
- **RSSI indicator** - Signal strength shown when connected
- **Manual reconnect** - Reconnect button visible when disconnected
- **MTU negotiation** - Requests 512-byte MTU to prevent JSON truncation
- **Backward Compatibility** - App supports v2.0, v3.0, and v4.0 firmware automatically

### Data Storage
- Real-time data displayed on Safety tab
- Alert history stored in Firebase (safety_alerts collection)
- Sensor data logged to Firebase (sensor_data collection)

---

## 7. Export & Reports

### PDF Reports
Professional documentation for each finding:
- Cover page with finding name
- Metadata grid layout
- Photo gallery (up to 6 images)
- Measurement tables
- Scientific annotations
- Institutional footer

### Data Export
- **JSON** - All findings as structured data
- **PLY** - 3D point clouds
- **Share** - Via system share dialog

### Batch Operations
- Select multiple findings
- Export all to single file
- Share directly from app

---

## 8. Tools Menu

Quick access hub for all features:

### Hero Feature Card
- **3D Reconstruction** - Prominent display
- Shows algorithm badges (RANSAC, Triple Validation)
- Success rate indicator (85-95%)

### Field Work Section
- **Field Journal** - Daily excavation logging
- Voice notes support
- GPS-tagged entries
- Searchable archive

### Capture & Documentation
- Manual Entry Form
- Quick Photo Capture

### AI & 3D
- **Coin AI** - AI-powered coin identification and classification
- **Photogrammetry** - 3D reconstruction from photos (also accessible from Findings tab)

### Export & Reports
- PDF Report Generator
- JSON/CSV Data Export
- GeoJSON/KML for GIS
- 3D Model Export

---

## 9. Analytics Dashboard

Professional statistics and progress tracking for archaeological fieldwork.

### Summary Statistics
| Metric | Description |
|--------|-------------|
| Total Documented | All-time finding count |
| Today's Findings | Documented in last 24 hours |

### Weekly Activity Chart
- Bar chart showing findings per day
- 7-day rolling view
- Visual trend identification

### Documentation Statistics
| Stat | Description |
|------|-------------|
| Avg. per Day | Daily documentation rate |
| Most Active Day | Highest productivity day |
| Time Active | Total documentation hours |
| Sites Covered | Number of excavation sites |

### Session Summary
- Current session duration
- Session statistics
- Quick actions

---

## 10. Field Journal

Digital excavation diary for daily observations and notes.

### Entry Management
- Create, edit, delete entries
- Rich text support
- Timestamp and date tracking

### Features
- **Search** - Full-text search across entries
- **Tags** - Categorize entries for filtering
- **Export** - Include journal in reports

### Best Practices
- Daily start/end entries
- Weather conditions logging
- Team member documentation
- Interpretation notes

---

## 11. Offline Support

### Auto-Save System
- Form drafts saved every 2 seconds
- Triggered on any text change
- Survives app crashes

### Draft Recovery
- Automatic prompt on app launch
- "Resume" or "Discard" options
- Full form state preserved

### Offline Queue
- Findings saved locally when offline
- Automatic sync when online
- Visual indicator of pending uploads

### Local Cache
- Recent findings cached
- Browse without internet
- Images stored locally

### Sync Features
- "Sync Now" manual trigger
- Background sync when online
- Conflict resolution (server wins)

---

## 12. Settings & Customization

### Appearance
- Theme selection (Light/Dark/System)
- Accent color picker (10 options)
- Font size adjustment
- Compact mode toggle

### Regional
- Measurement units (Metric/Imperial)
- Date format preferences
- Language selection

### Data & Sync
- Auto-sync toggle
- Offline mode
- Image compression settings
- Image quality (1-100)

### Privacy & Security
- Biometric authentication (fingerprint/face)
- Analytics opt-in/out

### Field Work Settings
- Auto-save interval
- GPS coordinate display
- Auto weather recording

### 3D & Photogrammetry
- Cloud vs on-device processing
- High quality preview
- Max photos per scan

---

## 13. Quick Capture

Simplified single-photo documentation for rapid field recording.

### Purpose
Quick capture provides a streamlined workflow for documenting finds without full form completion. Ideal for:
- Initial discovery documentation
- Rapid site surveys
- In-situ photography before excavation
- Time-sensitive situations

### Capture Workflow
1. **Take Photo** - Single tap capture
2. **Review** - Verify image quality
3. **Select Type** - Choose artifact category
4. **Add Description** - Optional notes
5. **Auto GPS** - Location captured automatically
6. **Save** - Store to database

### Artifact Types
| Type | Icon | Color |
|------|------|-------|
| Pottery | Amphora | Orange |
| Bone | Bone | Cream |
| Metal | Shield | Gray |
| Stone | Mountain | Brown |
| Glass | Wine Glass | Cyan |
| Organic | Leaf | Green |
| Coin | Circle | Gold |
| Jewelry | Diamond | Purple |
| Architecture | Building | Blue |
| Other | Question | Gray |

### Features
- **One-Tap Capture** - Minimal interface
- **Auto GPS** - Location embedded
- **Type Classification** - Quick category selection
- **Optional Description** - Add notes if needed
- **Retake Option** - Easy redo before saving
- **Integration** - Links to full documentation system

---

## 14. Data Validation

Automatic data quality checks ensuring documentation completeness and accuracy.

### Validation Levels
| Level | Icon | Action |
|-------|------|--------|
| Error | Red X | Blocks saving |
| Warning | Orange ! | Allows save with notice |
| Info | Blue i | Suggestion only |

### Finding Validation
**Required Fields (Errors):**
- Name
- Type

**Recommended Fields (Warnings):**
- Context number
- GPS coordinates
- Photo attachment
- Description
- Material
- Historical period

### Context Sheet Validation
**Required Fields:**
- Context number
- Context type

**Recommended Fields:**
- Interpretation
- Top elevation
- Stratigraphic relationships

### Completeness Score
| Score | Rating | Color |
|-------|--------|-------|
| 90-100% | Excellent | Green |
| 70-89% | Good | Light Green |
| 50-69% | Fair | Orange |
| 0-49% | Incomplete | Red |

### Validation Dialog
When saving incomplete records:
- Shows completeness percentage
- Lists all errors (must fix)
- Lists all warnings (recommendations)
- "Fix Issues" or "Save Anyway" options

---

## Feature Matrix

| Feature | Status | Notes |
|---------|--------|-------|
| User Authentication | ✅ Complete | Email + Google |
| Findings CRUD | ✅ Complete | Full management |
| 3D Reconstruction | ✅ Complete | Real SfM + Cloud |
| Cloud Processing | ✅ Complete | OpenScan API |
| Photo Capture | ✅ Complete | Camera + Gallery |
| PDF Export | ✅ Complete | Professional |
| Trench Safety Monitoring v4.0 | ✅ Complete | DWT + Arias + CAV + Temp + Rule-based fallback |
| Offline Support | ✅ Complete | Auto-save + Queue |
| Cloud Database | ✅ Complete | Firebase Firestore |
| Field Journal | ✅ Complete | Daily logging |
| Analytics | ✅ Complete | Professional stats |
| Voice Commands | ✅ Complete | Speech-to-text |
| Biometric Auth | ✅ Complete | Fingerprint/Face |
| Settings Sync | ✅ Complete | Cross-device |
| Quick Capture | ✅ Complete | Simplified single-photo |
| Data Validation | ✅ Complete | Quality checks |
| ML Anomaly Detection v4.0 | ✅ Complete | VAE with 10 features + rule-based fallback |
| Low Power Mode v4.0 | ✅ Complete | 3s hold toggle, auto-escalation on elevated vibration |
| Coin AI | ✅ Complete | AI-powered coin identification |
| Reliability Suite v4.0 | ✅ Complete | Circular buffers, memory leak fixes, setState batching |
| Modular Architecture v4.0 | ✅ Complete | 25+ services, 181 tests |
