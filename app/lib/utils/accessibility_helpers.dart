import 'package:flutter/material.dart';
import '../services/vibration_anomaly_service.dart';

/// Accessibility helper functions.
///
/// Wrap safety-critical and interactive widgets with these helpers so that
/// screen readers (TalkBack / VoiceOver) can announce the correct semantic
/// information to users.
///
/// Usage:
/// ```dart
/// semanticSafetyLevel(level, MyBadgeWidget(level: level))
/// semanticPpvValue(ppv, MyGaugeWidget(ppv: ppv))
/// semanticButton('Reconnect', 'Reconnect to the sensor', reconnectButton)
/// ```

/// Wraps [child] with a [Semantics] label describing the current safety level.
///
/// Adds an optional [Semantics.hint] for elevated-risk states so the user
/// knows an action may be required.
Widget semanticSafetyLevel(AnomalyLevel level, Widget child) {
  final String hint;
  switch (level) {
    case AnomalyLevel.anomaly:
      hint = 'Elevated risk detected — consider evacuating the area';
      break;
    case AnomalyLevel.unusual:
      hint = 'Unusual vibration pattern — monitor closely';
      break;
    case AnomalyLevel.normal:
    case AnomalyLevel.unknown:
      hint = '';
      break;
  }

  return Semantics(
    label: 'Safety level: ${level.name}',
    hint: hint.isNotEmpty ? hint : null,
    child: child,
  );
}

/// Wraps [child] with a [Semantics] label announcing [ppv] in a natural-
/// language format suitable for screen readers.
Widget semanticPpvValue(double ppv, Widget child) {
  return Semantics(
    label: 'Peak particle velocity: ${ppv.toStringAsFixed(3)} millimetres per second',
    child: child,
  );
}

/// Wraps [child] with button semantics using a descriptive [label] and an
/// optional [hint] that explains what the button does.
Widget semanticButton(String label, String? hint, Widget child) {
  return Semantics(
    label: label,
    hint: hint,
    button: true,
    child: child,
  );
}

/// Wraps [child] with a [Semantics] label announcing an anomaly score.
Widget semanticAnomalyScore(double score, Widget child) {
  final pct = (score * 100).toStringAsFixed(1);
  return Semantics(
    label: 'Anomaly confidence: $pct percent',
    child: child,
  );
}

/// Wraps [child] with a [Semantics] label for a signal-strength / RSSI value.
Widget semanticRssi(int? rssi, Widget child) {
  final label = rssi != null
      ? 'Signal strength: $rssi dBm'
      : 'Signal strength unknown';
  return Semantics(
    label: label,
    child: child,
  );
}

/// Wraps [child] with a [Semantics] label announcing a session timer value.
Widget semanticSessionTimer(Duration elapsed, Widget child) {
  final h = elapsed.inHours;
  final m = elapsed.inMinutes.remainder(60);
  final s = elapsed.inSeconds.remainder(60);
  final readable = h > 0
      ? '$h hours $m minutes $s seconds'
      : m > 0
          ? '$m minutes $s seconds'
          : '$s seconds';

  return Semantics(
    label: 'Session active for $readable',
    child: child,
  );
}

/// Wraps a status text widget with a [Semantics] live-region so TalkBack /
/// VoiceOver will automatically re-read it when the value changes.
Widget semanticLiveRegion({required String label, required Widget child}) {
  return Semantics(
    label: label,
    liveRegion: true,
    child: child,
  );
}
