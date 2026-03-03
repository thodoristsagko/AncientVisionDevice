import 'package:flutter/foundation.dart';

/// Tracks BLE packet sequence numbers to detect missed packets.
///
/// The firmware sends `"seq":<uint32>` in every IMU JSON packet, incrementing
/// by 1 each time. Call [track] with each new packet's seq value to detect
/// gaps. Handles uint32 rollover (0xFFFFFFFF → 0).
class BlePacketTracker {
  int _lastSeq = -1;
  int _missedPackets = 0;
  int _totalPackets = 0;

  /// Call with each new packet's seq number.
  /// Returns number of missed packets since last call (usually 0).
  int track(int seq) {
    _totalPackets++;
    if (_lastSeq < 0) {
      _lastSeq = seq;
      return 0;
    }
    final expected = (_lastSeq + 1) & 0xFFFFFFFF; // handle uint32 rollover
    final missed = seq > expected ? seq - expected : 0;
    _missedPackets += missed;
    _lastSeq = seq;
    if (missed > 0) {
      debugPrint('[BLE] Missed $missed packets (seq $expected → $seq)');
    }
    return missed;
  }

  int get missedPackets => _missedPackets;
  int get totalPackets => _totalPackets;
  double get missRate => _totalPackets > 0 ? _missedPackets / _totalPackets : 0.0;

  void reset() {
    _lastSeq = -1;
    _missedPackets = 0;
    _totalPackets = 0;
  }
}
