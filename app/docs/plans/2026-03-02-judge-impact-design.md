# Judge Impact — Visual Polish Design

**Date:** 2026-03-02
**Competition:** Thessaloniki Finals, March 21–22, 2026
**Goal:** Make the app immediately impressive to both technical and project judges during a live, hands-on demo.

---

## Context

Judges interact live with the real app and M5StickC Plus 2 device. The Safety tab is shown first (pre-opened, script-based). During Q&A, judges get a full app tour. The Tools tab was identified as the weakest screen — too many uniform cards, no clear hierarchy.

---

## Feature 1: Tools Tab Hero Redesign

**Problem:** Every `ToolCard` looks identical. Judges don't know what to tap first.

**Solution:** Three-tier layout:

### Tier 1 — Hero Cards
Three full-width featured cards (~110px tall each):

| Card | Subtitle | Status Badge |
|------|----------|-------------|
| 🪙 AI Coin Recognition | "Identify coins using Google Gemini AI" | `Model ready` (green) / `No connection` (amber) |
| 📷 3D Photogrammetry | "Build 3D models from photos" | `Camera ready` |
| 📄 PDF Report | "Export all findings as a report" | `N findings` |

Each hero card: large icon left, title + subtitle centre, status badge top-right. Distinct gradient background per card (gold tint / blue tint / green tint over base dark teal).

### Tier 2 — Utilities
Remaining existing tool cards kept in the current 2-column grid, below a `"Utilities"` section header. No functionality removed.

### Tier 3 — Section Labels
`"Featured"` label above Tier 1. `"Utilities"` label above Tier 2.

**Files:** `lib/screens/tools_view.dart`

---

## Feature 2: Dashboard Animated Counters

**Problem:** Stats (Total / Today / Significant) appear statically — no sense of dynamism.

**Solution:** `AnimationController` (800ms, `CurvedAnimation(Curves.easeOut)`) drives a `Tween<int>` from 0 to each real value. Counters count up when the Dashboard loads. Uses existing `_totalFindings`, `_todayFindings`, `_significantFindings` values.

**Files:** `lib/screens/dashboard_home_view.dart`

---

## Feature 3: Findings Source Badges

**Problem:** Judges can't tell at a glance that findings were captured three different ways.

**Solution:** Small colored pill badge on each finding card showing capture method:

| Source | Label | Color |
|--------|-------|-------|
| AI recognition | `AI` | Amber `#FFC107` |
| Quick capture | `Quick` | Blue `#2196F3` |
| Manual entry | `Manual` | Grey `#78909C` |
| Photo | `Photo` | Purple `#9C27B0` |

Badge rendered in `FindingDetailCard` (or wherever finding cards are built in `findings_view.dart`). Single `_sourceBadge(FindingSource)` helper widget.

**Files:** `lib/screens/findings_view.dart` (finding card widget)

---

## Feature 4: Safety Tab Live Pulse Indicator

**Problem:** Judges glancing at the Safety tab don't immediately know if the BLE sensor is streaming live data.

**Solution:** Animated green dot next to the device name/status row:
- **Connected + streaming:** pulsing green dot (`AnimationController`, opacity 1.0→0.3, 1s repeat)
- **Connected + idle:** solid green dot (no pulse)
- **Disconnected:** solid grey dot

Implemented as a small `AnimatedBuilder` wrapping a `Container` (8px circle). Reuses the existing `_isConnected` / `_ppv` state already in `_SafetyViewState`.

**Files:** `lib/screens/safety/safety_view.dart`

---

## Implementation Order

All 4 features touch different files — implement in parallel:
- Feature 1: `tools_view.dart`
- Feature 2: `dashboard_home_view.dart`
- Feature 3: `findings_view.dart`
- Feature 4: `safety_view.dart`
