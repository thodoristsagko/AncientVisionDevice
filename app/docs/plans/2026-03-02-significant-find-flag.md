# Significant Find Flag Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "significant find" checkmark to the Manual Entry, Quick Capture, and AI Recognition screens so archaeologists can flag important finds at the moment of entry.

**Architecture:** Add `bool isSignificant = false` to the `Finding` model. Each of the three entry screens gets a `CheckboxListTile` that sets a local `_isSignificant` bool, which is included in the saved/returned data map. The Firestore loading block in `findings_view.dart` reads the new field. `FindingDetailCard` shows a gold star badge when `isSignificant` is true.

**Tech Stack:** Flutter, Firestore, `Finding` model in `lib/models/finding_model.dart`.

---

### Task 1: Add `isSignificant` field to `Finding` model

**Files:**
- Modify: `lib/models/finding_model.dart`

**Step 1: Add field and update constructor**

In `lib/models/finding_model.dart`, find the `Finding` class. After the existing `associatedFeatures` field (line ~69), add:

```dart
  final bool isSignificant;
```

In the constructor (after `this.associatedFeatures`), add:

```dart
    this.isSignificant = false,
```

**Step 2: flutter analyze**

```
flutter analyze lib/models/finding_model.dart
```
Expected: `No issues found!`

---

### Task 2: Update Firestore loading to read `isSignificant`

**Files:**
- Modify: `lib/screens/findings_view.dart`

**Step 1: Add field to `Finding(...)` constructor in the Firestore loading block**

In `findings_view.dart`, find the `Finding(` constructor call inside the `snapshot.docs.map(...)` block (around line 306). It ends with:

```dart
          associatedFeatures: data['associatedFeatures'] != null
              ? List<String>.from(data['associatedFeatures'])
              : null,
        );
```

Replace with:

```dart
          associatedFeatures: data['associatedFeatures'] != null
              ? List<String>.from(data['associatedFeatures'])
              : null,
          isSignificant: data['isSignificant'] ?? false,
        );
```

**Step 2: flutter analyze**

```
flutter analyze lib/screens/findings_view.dart
```
Expected: `No issues found!`

---

### Task 3: Add significance checkbox to Manual Entry form

**Files:**
- Modify: `lib/screens/manual_entry_form_screen.dart`

**Step 1: Add state variable**

In `_ManualEntryFormScreenState`, find the existing state fields (look for `bool _isSaving = false;`). Add next to it:

```dart
  bool _isSignificant = false;
```

**Step 2: Add `CheckboxListTile` before the submit button**

Find the `const SizedBox(height: 32),` comment `// SUBMIT BUTTON` block (around line 1280). Insert before it:

```dart
                  // Significant find toggle
                  CheckboxListTile(
                    value: _isSignificant,
                    onChanged: (v) => setState(() => _isSignificant = v ?? false),
                    title: const Text(
                      'Mark as significant find',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'e.g. gold coin, complete ceramic',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    activeColor: const Color(0xFFFFC107),
                    checkColor: const Color(0xFF0D3A39),
                    side: const BorderSide(color: Colors.white38),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 16),

```

**Step 3: Include in `findingData` map**

In `_saveFinding()`, find the `findingData` map (around line 551). It has entries like `'source': source,`. Add after it:

```dart
        'isSignificant': _isSignificant,
```

**Step 4: flutter analyze**

```
flutter analyze lib/screens/manual_entry_form_screen.dart
```
Expected: `No issues found!`

---

### Task 4: Add significance checkbox to Quick Capture review screen

**Files:**
- Modify: `lib/screens/quick_capture_screen.dart`
- Modify: `lib/screens/findings_view.dart`

**Step 1: Add state variable to `_QuickCaptureScreenState`**

Find the existing state fields. Add:

```dart
  bool _isSignificant = false;
```

**Step 2: Add `CheckboxListTile` in the review UI**

In the review `Scaffold`'s `body: SingleChildScrollView` column (around line 509, after the GPS info container), add:

```dart
            const SizedBox(height: AppSpacing.xl),

            // Significant find toggle
            CheckboxListTile(
              value: _isSignificant,
              onChanged: (v) => setState(() => _isSignificant = v ?? false),
              title: const Text(
                'Mark as significant find',
                style: AppTextStyles.body,
              ),
              subtitle: Text(
                'e.g. gold coin, complete ceramic',
                style: AppTextStyles.subtitleSmall,
              ),
              activeColor: AppColors.warning,
              checkColor: AppColors.primaryDark,
              side: const BorderSide(color: Colors.white38),
              contentPadding: EdgeInsets.zero,
            ),
```

**Step 3: Include in result map in `_saveFinding()`**

In `quick_capture_screen.dart`'s `_saveFinding()`, find the `result` map:

```dart
      final result = {
        'photo': _capturedPhoto,
        'persistedPath': persistedPath,
        'type': _selectedType,
        'description': _description,
        'location': _currentPosition != null
            ? {
                'latitude': _currentPosition!.latitude,
                'longitude': _currentPosition!.longitude,
              }
            : null,
      };
```

Add `'isSignificant': _isSignificant,` to it:

```dart
      final result = {
        'photo': _capturedPhoto,
        'persistedPath': persistedPath,
        'type': _selectedType,
        'description': _description,
        'location': _currentPosition != null
            ? {
                'latitude': _currentPosition!.latitude,
                'longitude': _currentPosition!.longitude,
              }
            : null,
        'isSignificant': _isSignificant,
      };
```

**Step 4: Pass through in `_handleQuickCaptureResult` in `findings_view.dart`**

In `findings_view.dart`'s `_handleQuickCaptureResult`, find the `findingData` map (around line 774). It ends with `'source': 'quick',`. Add after it:

```dart
    'isSignificant': result['isSignificant'] ?? false,
```

**Step 5: flutter analyze**

```
flutter analyze lib/screens/quick_capture_screen.dart lib/screens/findings_view.dart
```
Expected: `No issues found!`

---

### Task 5: Add significance checkbox to AI Recognition screen

**Files:**
- Modify: `lib/screens/ai_recognition_screen.dart`

**Step 1: Add state variable to `_AIRecognitionScreenState`**

Find the existing state fields. Add:

```dart
  bool _isSignificant = false;
```

**Step 2: Add `CheckboxListTile` after the coin result card**

Find the section in `build()` that shows when `_coinResult != null`. After the result display widget, add:

```dart
            if (_coinResult != null) ...[
              const SizedBox(height: 16),
              CheckboxListTile(
                value: _isSignificant,
                onChanged: (v) => setState(() => _isSignificant = v ?? false),
                title: const Text(
                  'Mark as significant find',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: const Text(
                  'e.g. rare coin, exceptional condition',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                activeColor: const Color(0xFFFFC107),
                checkColor: const Color(0xFF0D3A39),
                side: const BorderSide(color: Colors.white38),
                contentPadding: EdgeInsets.zero,
              ),
            ],
```

**Step 3: Include in `_useClassification()` result map**

Find `_useClassification()`:

```dart
  void _useClassification() {
    if (_coinResult == null) return;

    Navigator.pop(context, {
      'type': 'Coin',
      ...
    });
  }
```

Add `'isSignificant': _isSignificant,` to the map:

```dart
  void _useClassification() {
    if (_coinResult == null) return;

    Navigator.pop(context, {
      'type': 'Coin',
      'material': _coinResult!.material,
      'period': _coinResult!.period,
      'dateRange': _coinResult!.dateRange,
      'description': _coinResult!.description,
      'confidence': _coinResult!.confidence / 100,
      'imagePath': _obverseImage?.path,
      'isCoin': _coinResult!.isCoin,
      'characteristics': _coinResult!.characteristics,
      'regions': _coinResult!.regions,
      'isSignificant': _isSignificant,
    });
  }
```

**Step 4: flutter analyze**

```
flutter analyze lib/screens/ai_recognition_screen.dart
```
Expected: `No issues found!`

---

### Task 6: Show gold star badge in `FindingDetailCard`

**Files:**
- Modify: `lib/widgets/finding_detail_card.dart`

**Step 1: Add star icon next to the finding name**

In `finding_detail_card.dart`, find the Row containing the finding name (around line 90):

```dart
                        Row(
                          children: [
                            // Type color indicator
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: typeColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                finding.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
```

Replace with:

```dart
                        Row(
                          children: [
                            // Type color indicator
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: typeColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                finding.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (finding.isSignificant)
                              const Icon(
                                Icons.star,
                                color: Color(0xFFFFC107),
                                size: 18,
                              ),
                          ],
                        ),
```

**Step 2: flutter analyze**

```
flutter analyze lib/widgets/finding_detail_card.dart
```
Expected: `No issues found!`

---

### Task 7: Analyze, test, commit

**Files:**
- All modified files above
- `docs/plans/2026-03-02-significant-find-flag.md`

**Step 1: Full flutter analyze**

```
flutter analyze lib/models/finding_model.dart lib/screens/findings_view.dart lib/screens/manual_entry_form_screen.dart lib/screens/quick_capture_screen.dart lib/screens/ai_recognition_screen.dart lib/widgets/finding_detail_card.dart
```
Expected: `No issues found!`

**Step 2: Full test suite**

```
flutter test --reporter=compact
```
Expected: `+255: All tests passed!`

**Step 3: Commit**

```bash
git add lib/models/finding_model.dart \
        lib/screens/findings_view.dart \
        lib/screens/manual_entry_form_screen.dart \
        lib/screens/quick_capture_screen.dart \
        lib/screens/ai_recognition_screen.dart \
        lib/widgets/finding_detail_card.dart \
        docs/plans/2026-03-02-significant-find-flag.md
git commit -m "$(cat <<'EOF'
feat: add significant find flag to Manual, Quick Capture, and AI Recognition entries

Adds a 'Mark as significant find' checkbox to all three entry types.
Flagged findings display a gold star badge in the findings list.
Field persisted to Firestore as isSignificant boolean.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

Do NOT push yet.
