# Τεχνική Αρχιτεκτονική AncientVision

Αναλυτική παρουσίαση του σχεδιασμού συστήματος, αλγορίθμων και λεπτομερειών υλοποίησης.

---

## Πίνακας Περιεχομένων

1. [Αρχιτεκτονική Συστήματος](#αρχιτεκτονική-συστήματος)
2. [Αλγόριθμοι 3D Ανακατασκευής](#αλγόριθμοι-3d-ανακατασκευής)
3. [Επίπεδο Υπηρεσιών](#επίπεδο-υπηρεσιών)
4. [Μοντέλα Δεδομένων](#μοντέλα-δεδομένων)
5. [Ενσωμάτωση Firebase](#ενσωμάτωση-firebase)

---

## Αρχιτεκτονική Συστήματος

### Διάγραμμα Επιπέδων

```
┌─────────────────────────────────────────────────────────────┐
│                     ΕΠΙΠΕΔΟ ΠΑΡΟΥΣΙΑΣΗΣ                       │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐           │
│  │Dashboard│ │Ευρήματα │ │Εργαλεία │ │Ασφάλεια │           │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘           │
│       │           │           │           │                  │
│  ┌────┴───────────┴───────────┴───────────┴────┐           │
│  │              Βιβλιοθήκη Widgets               │           │
│  │  PointCloudPainter | Model3DViewer           │           │
│  └──────────────────────┬───────────────────────┘           │
└─────────────────────────┼───────────────────────────────────┘
                          │
┌─────────────────────────┼───────────────────────────────────┐
│                  ΕΠΙΠΕΔΟ ΕΠΙΧΕΙΡΗΣΙΑΚΗΣ ΛΟΓΙΚΗΣ              │
│  ┌──────────────────────┴───────────────────────┐           │
│  │                 Υπηρεσίες                      │           │
│  │  AuthService | FirebaseService | ImageService │           │
│  │  ReconstructionService | LocalStorageService  │           │
│  │  CloudPhotogrammetryService | RobustSfM       │           │
│  └──────────────────────┬───────────────────────┘           │
└─────────────────────────┼───────────────────────────────────┘
                          │
┌─────────────────────────┼───────────────────────────────────┐
│                     ΕΠΙΠΕΔΟ ΔΕΔΟΜΕΝΩΝ                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│  │ Firebase │  │  ImgBB   │  │  Τοπική  │                   │
│  │Firestore │  │   API    │  │Αποθήκευση│                   │
│  └──────────┘  └──────────┘  └──────────┘                   │
└─────────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────┼───────────────────────────────────┐
│                  ΕΠΙΠΕΔΟ ΥΛΙΚΟΥ                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│  │  Κάμερα  │  │   BLE    │  │   GPS    │                   │
│  │          │  │ M5StickC │  │          │                   │
│  └──────────┘  └──────────┘  └──────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### Δομή Αρχείων

```
lib/
├── main.dart                    # ~600 γραμμές - Κύρια εφαρμογή (από 13,472)
│   ├── MyApp                    # Root widget
│   ├── AuthScreen               # Σύνδεση/εγγραφή
│   ├── MainScreen               # Scaffold πλοήγησης
│   └── Οθόνες μεταφέρθηκαν σε ξεχωριστά αρχεία
│
├── screens/                     # ΝΕΟ v4.0 - Διαχωρισμός οθονών
│   ├── dashboard_screen.dart    # Στατιστικά & επισκόπηση
│   ├── findings_screen.dart     # Γκαλερί & χάρτης
│   ├── tools_screen.dart        # Κόμβος λειτουργιών
│   ├── safety_screen.dart       # Παρακολούθηση αισθητήρων
│   ├── manual_entry_screen.dart # Φόρμα τεκμηρίωσης
│   ├── photogrammetry_screen.dart # 3D λήψη
│   └── export_screens.dart      # Εξαγωγές PDF & δεδομένων
│
├── services/                    # 25+ υπηρεσίες (ήταν 7)
│   ├── auth_service.dart        # Firebase Auth wrapper + Ρόλοι
│   ├── firebase_service.dart    # Λειτουργίες Firestore
│   ├── reconstruction_service.dart  # 3D pipeline
│   ├── sfm_robust.dart          # Αλγόριθμοι SfM
│   ├── image_service.dart       # Συμπίεση & ανάλυση
│   ├── cloud_photogrammetry_service.dart # OpenScan Cloud
│   ├── local_storage_service.dart   # Υποστήριξη εκτός σύνδεσης
│   ├── vibration_anomaly_service.dart  # ΝΕΟ v4.0 - VAE ML μοντέλο
│   ├── wavelet_service.dart     # ΝΕΟ v4.0 - Haar DWT (23 tests)
│   ├── vibration_metrics_service.dart  # ΝΕΟ v4.0 - Arias/CAV (40 tests)
│   ├── exif_service.dart        # ΝΕΟ v4.0 - Μεταδεδομένα εικόνας (28 tests)
│   ├── reconstruction_quality_service.dart  # ΝΕΟ v4.0 - Βαθμολογία ποιότητας
│   ├── bundle_adjustment_service.dart  # ΝΕΟ v4.0 - Βελτιστοποίηση BA (15 tests)
│   └── metadata_export_service.dart  # ΝΕΟ v4.0 - Μορφές εξαγωγής (22 tests)
│
├── models/
│   ├── point_cloud.dart         # PointCloud, Point3D
│   ├── mesh_model.dart          # MeshModel, MeshVertex, MeshFace
│   └── reconstruction_result.dart   # Αποτελέσματα επεξεργασίας
│
├── widgets/
│   ├── point_cloud_painter.dart # 3D απόδοση
│   ├── model_3d_viewer.dart     # Διαδραστικός προβολέας
│   └── spectrogram_widget.dart  # ΝΕΟ v4.0 - Οπτικοποίηση συχνοτήτων (20 tests)
│
└── utils/
    ├── quality_analyzer.dart    # Μετρήσεις ποιότητας εικόνας
    └── validators.dart          # Επικύρωση δεδομένων
```

**Βελτιώσεις Αρχιτεκτονικής v4.0:**
- Main.dart μειώθηκε από 13,472 → ~600 γραμμές (μείωση 96%)
- 25+ αρθρωτές υπηρεσίες με σαφείς ευθύνες
- 181 unit tests (ήταν 31 σε v3.0) - αύξηση 484%
- Υπηρεσίες έτοιμες για μελλοντική ενσωμάτωση (wavelet, EXIF, bundle adjustment)

---

## Αλγόριθμοι 3D Ανακατασκευής

### Επισκόπηση Pipeline

```
Εικόνες → Εξαγωγή Χαρακτηριστικών → Αντιστοίχιση → Essential Matrix
    → RANSAC → Ανάκτηση Θέσης → Τριγωνοποίηση → Point Cloud
```

### Εξαγωγή Χαρακτηριστικών Harris Corner

Ο αλγόριθμος Harris corner ανιχνεύει γωνίες μετρώντας τη διακύμανση έντασης σε πολλαπλές κατευθύνσεις.

```dart
// Υπολογισμός πίνακα δομής Harris
Ix2 = (∂I/∂x)²
Iy2 = (∂I/∂y)²
IxIy = (∂I/∂x)(∂I/∂y)

// Απόκριση Harris
R = det(M) - k * trace(M)²
// όπου M = [[Ix2, IxIy], [IxIy, Iy2]]
```

### Αντιστοίχιση Χαρακτηριστικών

Αντιστοίχιση με βάση συσχέτιση πάνω σε παράθυρα patch.

| Παράμετρος | Τιμή | Σκοπός |
|------------|------|--------|
| Μέγεθος Patch | 16x16 | Περιοχή αντιστοίχισης |
| Κατώφλι Συσχέτισης | 0.75 | Ελάχιστη ομοιότητα |

### Αλγόριθμος 8 Σημείων - Essential Matrix

```dart
// Περιορισμός Epipolar
x₂ᵀ E x₁ = 0

// Κατασκευή πίνακα εξισώσεων A
A = [x₁'x₂', x₁'y₂', x₁', y₁'x₂', y₁'y₂', y₁', x₂', y₂', 1]

// Επίλυση για E χρησιμοποιώντας SVD
E = reshape(nullspace(A))
```

### RANSAC Outlier Rejection

```dart
for iteration in range(1000):
    // 1. Τυχαία επιλογή 8 αντιστοιχιών
    sample = random_sample(matches, 8)

    // 2. Εκτίμηση Essential Matrix
    E = compute_essential_matrix(sample)

    // 3. Μέτρηση inliers (σφάλμα < κατώφλι)
    inliers = count_inliers(E, all_matches, threshold=0.02)

    // 4. Ενημέρωση καλύτερου μοντέλου
    if inliers > best_inliers:
        best_E = E
        best_inliers = inliers
```

| Παράμετρος | Τιμή |
|------------|------|
| Επαναλήψεις | 1000 |
| Κατώφλι | 0.02 |
| Ελάχιστο Ποσοστό Inlier | 15% |

### Τριγωνοποίηση

```dart
// Δεδομένων πινάκων προβολής P1, P2 και σημείων x1, x2
// Επίλυση για 3D σημείο X

A = [
    x1 * P1[2] - P1[0],
    y1 * P1[2] - P1[1],
    x2 * P2[2] - P2[0],
    y2 * P2[2] - P2[1]
]

// SVD επίλυση
X = nullspace(A)
```

---

## Επίπεδο Υπηρεσιών

### AuthService

Διαχειρίζεται ταυτοποίηση χρηστών και ρόλους.

```dart
class AuthService {
  // Σταθερές ρόλων
  static const String roleAdmin = 'admin';
  static const String roleArcheologist = 'archeologist';
  static const String roleViewer = 'viewer';

  // Μέθοδοι ταυτοποίησης
  static Future<UserCredential> registerWithEmail(...);
  static Future<UserCredential?> loginWithEmail(...);
  static Future<UserCredential?> signInWithGoogle();

  // Διαχείριση ρόλων
  static Future<String> getCurrentUserRole();
  static Future<bool> isCurrentUserAdmin();
  static Future<bool> updateUserRole(String uid, String role);
}
```

### ReconstructionService

Ενορχηστρώνει το 3D pipeline.

```dart
class ReconstructionService {
  // Κύρια μέθοδος επεξεργασίας
  Future<ReconstructionResult> processImages(List<File> images);

  // Επιμέρους βήματα
  List<List<Point>> _extractFeatures(img.Image image);
  List<FeatureMatch> _matchFeatures(features1, features2);
  Matrix4? _estimateRelativePose(matches);
  List<Point3D> _triangulatePoints(matches, P1, P2);
}
```

### CloudPhotogrammetryService

Ενσωμάτωση με OpenScan Cloud API.

```dart
class CloudPhotogrammetryService {
  static const String _baseUrl = 'https://openscan.eu/public/api/photogrammetry';

  Future<String?> uploadAndProcess(List<File> images);
  Future<Map<String, dynamic>> checkServerStatus();
  Future<String?> downloadResult(String taskId);
}
```

---

## Μοντέλα Δεδομένων

### Finding (Εύρημα)

```dart
class _Finding {
  final String id;
  final String name;
  final String type;
  final String site;
  final String date;
  final String description;
  final double latitude;
  final double longitude;
  final String? imageUrl;
  final List<String> photoGallery;
  final String? model3dUrl;

  // Αρχαιολογικά πεδία
  final String? findNumber;
  final String? excavationUnit;
  final String? stratigraphicLayer;
  final double? depthBelowSurface;
  final double? lengthMm;
  final double? widthMm;
  final double? heightMm;
  final double? weightGrams;
  final String? material;
  final String? condition;
  final String? period;
}
```

### PointCloud

```dart
class PointCloud {
  final List<Point3D> points;
  final int? width;
  final int? height;

  String toPLY();  // Εξαγωγή
  factory PointCloud.fromPLY(String content);  // Εισαγωγή
}

class Point3D {
  final double x, y, z;
  final int r, g, b;
}
```

### ReconstructionResult

```dart
class ReconstructionResult {
  final PointCloud? pointCloud;
  final MeshModel? mesh;
  final int featureCount;
  final int matchCount;
  final double reprojectionError;
  final double coverage;
  final Duration processingTime;
  final String? errorMessage;

  bool get isSuccess;
  double get qualityScore;
}
```

---

## Ενσωμάτωση Firebase

### Firestore Schema

```
firestore/
├── users/
│   └── {uid}/
│       ├── email: string
│       ├── fullName: string
│       ├── role: "admin" | "archeologist" | "viewer"
│       ├── status: "active" | "suspended"
│       ├── createdAt: timestamp
│       └── lastActivity: timestamp
│
├── findings/
│   └── {findingId}/
│       ├── name: string
│       ├── type: string
│       ├── site: string
│       ├── date: string
│       ├── description: string
│       ├── latitude: number
│       ├── longitude: number
│       ├── imageUrl: string
│       ├── photoGallery: string[]
│       ├── model3dUrl: string
│       ├── createdAt: timestamp
│       └── userId: string
│
└── account_logs/
    └── {logId}/
        ├── action: string
        ├── userId: string
        ├── email: string
        ├── details: string
        └── timestamp: timestamp
```

### Κανόνες Ασφαλείας

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Χρήστες: ανάγνωση δικών τους, admins διαβάζουν όλα
    match /users/{userId} {
      allow read: if request.auth.uid == userId ||
                     get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';
      allow write: if request.auth.uid == userId ||
                      get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';
    }

    // Ευρήματα: ανάγνωση από όλους, εγγραφή από archeologist+
    match /findings/{findingId} {
      allow read: if request.auth != null;
      allow write: if request.auth != null &&
                      get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role in ['admin', 'archeologist'];
    }
  }
}
```

---

## Βελτιώσεις Αξιοπιστίας & Ασφάλειας v4.0

### Κυκλικοί Buffers (O(1) vs O(N))
Αντικατάσταση 7 περιπτώσεων `list.removeAt(0)` (O(N) μετατόπιση) με `CircularBuffer<T>` που βασίζεται σε `Queue<T>` (O(1) dequeue). Επηρεάζει `safety_view.dart` (6 buffers) και `spectrogram_widget.dart` (1 buffer).

**Ακαδημαϊκή βάση**: Knuth (1997) "The Art of Computer Programming, Vol. 1" Section 2.2.2

### Εναλλακτικό Σύστημα Ανίχνευσης Ανωμαλιών Βασισμένο σε Κανόνες
Όταν το μοντέλο TFLite δεν είναι διαθέσιμο, μια μηχανή βαθμολόγησης με βάρη χρησιμοποιεί:
- PPV (όρια κληρονομιάς DIN 4150-3) — 30%
- STA/LTA (σεισμικός trigger Allen 1978) — 20%
- CAV (όριο ζημιάς EPRI 0.16 g·s) — 15%
- Crest factor (ανίχνευση κρούσης ISO 10816) — 10%
- Kurtosis (ανίχνευση παλμικού συμβάντος) — 10%
- Ανάλυση σεισμικής συχνότητας (0.5-10 Hz) — 10%
- RMS ενέργεια (συνεχόμενη δόνηση) — 5%

**Κρίσιμο**: Η ανίχνευση ανωμαλιών ΠΟΤΕ δεν απενεργοποιείται. Τόσο η διαδρομή ML όσο και η διαδρομή βασισμένη σε κανόνες παράγουν έγκυρες βαθμολογίες ανωμαλιών και ταξινομήσεις.

### Αυτόματη Κλιμάκωση Ασφάλειας Λειτουργίας Χαμηλής Κατανάλωσης
Το firmware παραλείπει FFT/DWT/kurtosis σε λειτουργία χαμηλής κατανάλωσης για εξοικονόμηση μπαταρίας. Αλλά όταν το PPV υπερβαίνει το PPV_SAFE_MAX (0.3 mm/s), αυτόματα κλιμακώνει στην πλήρη επεξεργασία DSP για αυτό το παράθυρο, διασφαλίζοντας ότι οι κανόνες κινδύνου που εξαρτώνται από τη συχνότητα (σεισμική, μηχανήματα, παροδική DWT) εξακολουθούν να ενεργοποιούνται.

### Διορθώσεις Διαρροής Μνήμης
- `anomalyService.dispose()` καλείται στη dispose του SafetyView
- LRU cache (50 καταχωρήσεις) στην υπηρεσία ταξινόμησης AI
- `clearCache()` στην υπηρεσία ανακατασκευής μετά την ολοκλήρωση
- Παρακολούθηση προσωρινών αρχείων και καθαρισμός στην υπηρεσία εικόνας

### Ομαδοποίηση setState
Η αναβαλλόμενη επεξεργασία του SafetyView ενοποιήθηκε σε μονό `setState` + `Future.microtask` + `RepaintBoundary` γύρω από ακριβά widgets γραφημάτων.

### Ομαδοποίηση Ουράς Εκτός Σύνδεσης
Αντικαταστάθηκαν οι διαδοχικές εγγραφές Firestore με `WriteBatch` (μέγιστο 500 ops) και εκθετική αναστολή μεταξύ επαναπροσπαθειών.

### Ανθεκτικότητα Σύνδεσης BLE
- Δείκτης ισχύος σήματος RSSI
- Polling keepalive 3 δευτερολέπτων (ήταν 5s)
- Χειροκίνητο κουμπί επανασύνδεσης όταν είναι αποσυνδεδεμένο
- Αριθμός προσπαθειών στην κατάσταση σύνδεσης

---

## Βελτιστοποιήσεις Απόδοσης

### Συμπίεση Εικόνας

**Πριν:** 5 MB ανά φωτογραφία
**Μετά:** 500 KB ανά φωτογραφία (μείωση 90%)

```dart
// Στρατηγική συμπίεσης
final compressedFile = await imageService.compressImage(
  originalFile,
  maxWidth: 1920,    // Μέγιστη διάσταση
  maxHeight: 1920,
  quality: 85,       // Ποιότητα JPEG
);
```

### Διαχείριση Μνήμης

```dart
// Υποδειγματοληψία μεγάλων εικόνων για ανακατασκευή
img.Image _downsampleIfNeeded(img.Image image) {
  const maxDimension = 1024;
  if (image.width > maxDimension || image.height > maxDimension) {
    final scale = maxDimension / max(image.width, image.height);
    return img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
    );
  }
  return image;
}
```

### Παράλληλη Επεξεργασία

```dart
// Εξαγωγή χαρακτηριστικών παράλληλα
final futures = images.map((img) => compute(_extractFeatures, img));
final allFeatures = await Future.wait(futures);
```

### Ουρά Εκτός Σύνδεσης

```dart
// Αποθήκευση τοπικά αν είναι εκτός σύνδεσης
try {
  await FirebaseFirestore.instance
      .collection('findings')
      .doc(id)
      .set(data)
      .timeout(Duration(seconds: 15));
} catch (e) {
  await LocalStorageService().queueForUpload(
    findingId: id,
    data: data,
  );
}
```

---

## Εξαρτήσεις

### Βασικό Flutter

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| flutter | SDK | Framework |
| cupertino_icons | ^1.0.6 | Εικονίδια iOS |

### Firebase

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| firebase_core | ^2.24.2 | Αρχικοποίηση Firebase |
| cloud_firestore | ^4.14.0 | Βάση δεδομένων |
| firebase_auth | ^4.16.0 | Ταυτοποίηση |
| firebase_storage | ^11.6.0 | Αποθήκευση αρχείων |

### Ταυτοποίηση

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| google_sign_in | ^6.2.1 | Google OAuth |

### Χάρτες & Τοποθεσία

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| flutter_map | ^6.1.0 | Widget χάρτη |
| latlong2 | ^0.9.0 | Συντεταγμένες |

### Κάμερα & Πολυμέσα

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| image_picker | ^1.0.7 | Λήψη φωτογραφίας |
| camera | ^0.10.5+9 | Έλεγχος κάμερας |
| video_player | ^2.8.2 | Αναπαραγωγή βίντεο |
| image | ^4.1.7 | Επεξεργασία εικόνας |

### 3D & Μαθηματικά

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| vector_math | ^2.1.4 | Μαθηματικά 3D |
| model_viewer_plus | ^1.7.0 | Προβολέας 3D |

### Αισθητήρες & BLE

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| flutter_blue_plus | ^1.31.0 | Bluetooth |
| sensors_plus | ^4.0.2 | IMU, πυξίδα |

### Φωνή

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| speech_to_text | ^6.6.0 | Φωνητική είσοδος |
| flutter_tts | ^4.0.2 | Φωνητική έξοδος |

### Αποθήκευση & Αρχεία

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| shared_preferences | ^2.2.2 | Τοπικό αποθηκευτικό χώρο KV |
| path_provider | ^2.1.1 | Διαδρομές αρχείων |
| archive | ^3.4.10 | Αρχεία ZIP |

### Εξαγωγή & Κοινοποίηση

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| pdf | ^3.10.7 | Δημιουργία PDF |
| share_plus | ^7.2.1 | Διάλογος κοινοποίησης |

### Βοηθητικά Προγράμματα

| Πακέτο | Έκδοση | Σκοπός |
|--------|--------|--------|
| http | ^1.1.0 | Αιτήματα HTTP |
| uuid | ^4.2.2 | Δημιουργία UUID |
| intl | ^0.19.0 | Μορφοποίηση ημερομηνίας |

---

## Στατιστικά Έργου v4.0

| Μετρική | Τιμή |
|---------|------|
| Γραμμές Κώδικα | ~15,000 |
| Αρχεία Dart | 40+ |
| Υπηρεσίες | 25+ |
| Μοντέλα | 8 |
| Widgets | 12 |
| Unit Tests | 181 |
| Υποστηριζόμενες Πλατφόρμες | Android |

---

*Τεκμηρίωση για FLL 2025-2026 Innovation Project*
