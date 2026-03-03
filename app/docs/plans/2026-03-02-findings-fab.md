# Findings FAB Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a prominent `+` floating action button on the Findings tab so recording is always 2 taps away (FAB → bottom sheet → entry screen).

**Architecture:** The main `Scaffold` in `main.dart` gains a `floatingActionButton` shown only when `_currentIndex == 1`. The button calls `showAddOptions` on `FindingsViewState` (made public via `GlobalKey`). The existing small `+` button in the findings header row is removed to avoid duplication.

**Tech Stack:** Flutter, `lib/main.dart`, `lib/screens/findings_view.dart`.

---

### Task 1: Make `FindingsViewState` and `showAddOptions` accessible

**Files:**
- Modify: `lib/screens/findings_view.dart`

**Step 1: Make the state class public**

Find:
```dart
class _FindingsViewState extends State<FindingsView> {
```
Replace with:
```dart
class FindingsViewState extends State<FindingsView> {
```

**Step 2: Make `_showAddOptions` public**

Find:
```dart
  void _showAddOptions(BuildContext context) {
```
Replace with:
```dart
  void showAddOptions(BuildContext context) {
```

**Step 3: Update the internal call site**

Find inside `_FindingsViewState` (now `FindingsViewState`):
```dart
        onTap: () => _showAddOptions(context),
```
Replace with:
```dart
        onTap: () => showAddOptions(context),
```

**Step 4: Remove the small `+` header button**

Find and remove the entire GestureDetector block (it starts with the comment and ends after the closing paren):
```dart
                    // Add button (FAB-style) - opens bottom sheet with options
                    GestureDetector(
                        onTap: () => showAddOptions(context),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFC107),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.add_rounded,
                            color: Color(0xFF3E2723),
                            size: 22,
                          ),
                        ),
                      ),
```

Also remove the `const Spacer(),` line immediately before it (the spacer was only there to push the button to the right).

**Step 5: flutter analyze**

```
flutter analyze lib/screens/findings_view.dart
```
Expected: `No issues found!`

---

### Task 2: Add FAB to the main Scaffold

**Files:**
- Modify: `lib/main.dart`

**Step 1: Import FindingsView state (already imported via findings_view.dart)**

No new import needed — `FindingsView` is already imported.

**Step 2: Add `GlobalKey` for `FindingsView`**

In `_DashboardScreenState`, find the existing fields (e.g. `int _currentIndex = 3;`). Add after it:

```dart
  final _findingsKey = GlobalKey<FindingsViewState>();
```

**Step 3: Pass the key to `FindingsView`**

In `_buildBody()`, find:
```dart
        const FindingsView(),
```
Replace with:
```dart
        FindingsView(key: _findingsKey),
```

**Step 4: Add `floatingActionButton` to the Scaffold**

Find the Scaffold in `build()`:
```dart
          Scaffold(
            extendBody: true,
            backgroundColor: Colors.transparent,
            body: _buildBody(),
            bottomNavigationBar: SafeArea(
```
Replace with:
```dart
          Scaffold(
            extendBody: true,
            backgroundColor: Colors.transparent,
            body: _buildBody(),
            floatingActionButton: _currentIndex == 1
                ? FloatingActionButton(
                    onPressed: () {
                      final ctx = _findingsKey.currentContext;
                      if (ctx != null) {
                        _findingsKey.currentState?.showAddOptions(ctx);
                      }
                    },
                    backgroundColor: const Color(0xFFFFC107),
                    foregroundColor: const Color(0xFF3E2723),
                    child: const Icon(Icons.add_rounded),
                  )
                : null,
            bottomNavigationBar: SafeArea(
```

**Step 5: flutter analyze**

```
flutter analyze lib/main.dart
```
Expected: `No issues found!`

---

### Task 3: Analyze, test, commit

**Files:**
- `lib/main.dart`
- `lib/screens/findings_view.dart`
- `docs/plans/2026-03-02-findings-fab.md`

**Step 1: Full flutter analyze**

```
flutter analyze lib/main.dart lib/screens/findings_view.dart
```
Expected: `No issues found!`

**Step 2: Full test suite**

```
flutter test --reporter=compact
```
Expected: `All tests passed!`

**Step 3: Commit**

```bash
git add lib/main.dart lib/screens/findings_view.dart docs/plans/2026-03-02-findings-fab.md
git commit -m "$(cat <<'EOF'
feat: add prominent FAB to Findings tab for 2-tap recording

Replaces the small header + button with a full FloatingActionButton
shown only on the Findings tab. Tapping it opens the Add Finding
bottom sheet (Quick Capture / Manual Entry / Coin AI).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

Do NOT push yet.
