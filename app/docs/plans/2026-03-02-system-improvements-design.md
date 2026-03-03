# System Improvements Design — Competition Sprint

**Date:** 2026-03-02
**Competition:** Thessaloniki Finals, March 21–22, 2026
**Goal:** Maximise competition impact across Safety, Archaeology, AI, and Reliability sectors.

---

## Scope: 7 Features

| # | Feature | Area | Files touched |
|---|---------|------|--------------|
| 1 | Alert history log | Safety | new `AlertHistoryService`, `safety_view.dart` |
| 2 | Findings dashboard stats | Archaeology | `dashboard_home_view.dart` |
| 3 | Voice description input | Archaeology | `manual_entry_form_screen.dart` |
| 4 | Coin AI confidence ring | AI | `ai_recognition_screen.dart` |
| 5 | Vibration calibration baseline | Safety | `safety_view.dart`, `settings_service.dart` |
| 6 | Offline demo mode | Reliability | `findings_view.dart`, new asset |
| 7 | Site management | Archaeology | new `SiteService`, `findings_view.dart`, all 3 entry screens, `dashboard_home_view.dart` |

**All packages already in pubspec.yaml** — no new dependencies.

---

## Feature 1: Alert History Log

**Architecture:**
- New `lib/services/alert_history_service.dart` stores alerts in `SharedPreferences` as a JSON list (max 100 entries, FIFO eviction).
- Each entry: `{ timestamp, level, type, ppv, message }`.
- `safety_view.dart` calls `AlertHistoryService().add(...)` every time `onAlert` fires.
- A "History" `IconButton` in the Safety tab header opens a `showModalBottomSheet` with a scrollable `ListView` of alert tiles. Critical = red, warning = amber. Relative timestamps ("2 min ago"). Clear-all button at top.

---

## Feature 2: Findings Dashboard Stats

**Architecture:**
- `DashboardHomeView` gains a stats card below existing content.
- On mount, fires a Firestore query (`collection('findings').get()`) with 10s timeout.
- Renders via `fl_chart` (already in pubspec):
  - Bar chart: finds per day, last 7 days.
  - Row counters: Total · Significant · Active sites.
  - Mini breakdown row: Coin / Fragment / Structure / Other counts.
- Tapping card navigates to `AnalyticsScreen`.
- On Firestore error: shows zero-state silently (no crash).

---

## Feature 3: Voice Description Input

**Architecture:**
- `manual_entry_form_screen.dart`: mic `IconButton` at trailing edge of the Description `TextField`.
- Tap → request microphone permission via `permission_handler` → start `speech_to_text` listening.
- Button turns red and pulses (`AnimationController`) while listening.
- Tap again (or 30s timeout) → stop listening → append transcript to description controller.
- Error states: permission denied → `SnackBar`; speech not available → button hidden.

---

## Feature 4: Coin AI Confidence Ring

**Architecture:**
- `ai_recognition_screen.dart`: replace plain confidence `Text` widget.
- `AnimationController` (1s, `CurvedAnimation(Curves.easeOut)`) drives a `CircularProgressIndicator` value from 0 → `confidence / 100`.
- Colour: `green` ≥ 0.70, `amber` 0.50–0.69, `red` < 0.50.
- Confidence percentage rendered in the centre with `Stack`.
- Animation starts when `_coinResult` is set in `setState`.

---

## Feature 5: Vibration Calibration Baseline

**Architecture:**
- `SettingsService` gains `double calibrationBaselinePpv` field (default `0.0`).
- `safety_view.dart` gets a "Calibrate" `TextButton` in the header.
- Tap → 5-second sampling window collecting incoming PPV values from the BLE data stream → compute mean → save via `_settingsService.updateSetting('calibrationBaselinePpv', mean)`.
- UI shows current baseline value and a "Reset to 0" option.
- Threshold comparisons subtract baseline: `effectivePpv = ppv - calibrationBaselinePpv`.

---

## Feature 6: Offline Demo Mode

**Architecture:**
- New asset `assets/data/demo_findings.json`: 8 pre-built Kalapodi findings (2 coins, 3 ceramic fragments, 1 bone, 1 structural feature, 1 iron tool; mix of significant/normal, realistic coords near Kalapodi ~38.72°N 22.87°E).
- `findings_view.dart` Firestore fetch wrapped in try/catch with 10s timeout.
- On failure: load demo findings from asset, set `_isDemoMode = true`.
- Amber "Demo Mode" banner appears at top of list when `_isDemoMode` is true.
- Banner disappears on successful real-data reload.
- Demo findings not saveable/deletable (write operations blocked in demo mode).

---

## Feature 7: Site Management

**Architecture:**
- New `lib/services/site_service.dart`: stores `List<String> sites` and `String activeSite` in `SharedPreferences`. Methods: `getSites()`, `addSite(name)`, `setActiveSite(name)`, `removeSite(name)`.
- `FindingsView` header gains a site selector chip (shows active site name). Tap → bottom sheet with site list + "＋ New Site" option.
- All 3 entry screens (`manual_entry_form_screen.dart`, `quick_capture_screen.dart`, `ai_recognition_screen.dart`) pre-fill the site field with `SiteService().activeSite`.
- `DashboardHomeView` shows active site name prominently below the header.
- No `Finding` model change needed — `site` field already exists.

---

## Implementation Order

**Phase 1 — Parallel (features 1–4, independent files):**
Run subagents concurrently for 1, 2, 3, 4.

**Phase 2 — Sequential (features 5–7, shared files):**
5 → 6 → 7 in order (each touches different files, but 6 and 7 both touch `findings_view.dart` so must be sequential).
