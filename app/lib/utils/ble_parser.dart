import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Result of parsing BLE characteristic data.
sealed class BleParseResult {}

class ImuData extends BleParseResult {
  final double x, y, z, vib, ppv, rms, freq, crest, cent, kurt, stalta;
  final double arias, cav, temp, dwt1, dwt2, dwt3; // v4.0 fields
  final double peak; // v5.0: peak acceleration
  final int seq; // v5.1: firmware sequence number for missed-packet detection

  ImuData({
    required this.x,
    required this.y,
    required this.z,
    required this.vib,
    this.ppv = 0,
    this.rms = 0,
    this.freq = 0,
    this.crest = 0,
    this.cent = 0,
    this.kurt = 0,
    this.stalta = 0,
    this.arias = 0,
    this.cav = 0,
    this.temp = 0,
    this.dwt1 = 0,
    this.dwt2 = 0,
    this.dwt3 = 0,
    this.peak = 0,
    this.seq = 0,
  });
}

class RawAccelData extends BleParseResult {
  final List<double> accelX;
  final List<double> accelY;
  final List<double> accelZ;
  final int sampleCount;

  RawAccelData({required this.accelX, required this.accelY, required this.accelZ, required this.sampleCount});
}

class MoistureData extends BleParseResult {
  final int percent;
  final int raw;
  final double? vib;

  MoistureData({required this.percent, required this.raw, this.vib});
}

class AlertBleData extends BleParseResult {
  final String level;
  final String message;
  final String type;

  AlertBleData({required this.level, required this.message, required this.type});
}

class BatteryData extends BleParseResult {
  final double voltage;
  final int percent;
  final bool charging;

  BatteryData({required this.voltage, required this.percent, required this.charging});
}

class BleParseError extends BleParseResult {
  final String reason;
  BleParseError(this.reason);
}

/// Reassembles multi-packet raw acceleration data from BLE.
/// Firmware sends 256 * 3 axes * 2 bytes = 1536 bytes in 3 packets of 512.
/// Each packet has a 2-byte header: [sequenceNum, sampleCount].
class RawAccelReassembler {
  final Map<int, List<int>> _packets = {};
  int _expectedSamples = 256;
  DateTime? _firstPacketTime;
  static const Duration _packetTimeout = Duration(seconds: 5);

  /// Feed a raw BLE packet. Returns complete RawAccelData when all packets received.
  RawAccelData? addPacket(List<int> rawBytes) {
    if (rawBytes.length < 4) return null;

    final seqNum = rawBytes[0];
    // Firmware sends FFT_SAMPLES>>1 (128) since 256 overflows uint8
    final rawCount = rawBytes[1];
    _expectedSamples = rawCount <= 128 ? rawCount * 2 : rawCount;
    final data = rawBytes.sublist(2);

    // Start timeout timer on first packet (sequence 0)
    if (seqNum == 0) {
      _firstPacketTime = DateTime.now();
    }

    // Check for timeout: if first packet arrived >5s ago, reset
    if (_firstPacketTime != null && DateTime.now().difference(_firstPacketTime!) > _packetTimeout) {
      _packets.clear();
      _firstPacketTime = DateTime.now();
    }

    _packets[seqNum] = data;

    // Check if we have all packets
    final totalBytes = _expectedSamples * 3 * 2; // samples * axes * int16
    const packetSize = 200;
    final expectedPackets = (totalBytes + packetSize - 1) ~/ packetSize;

    if (_packets.length < expectedPackets) return null;

    // Reassemble
    final allBytes = <int>[];
    for (int i = 0; i < expectedPackets; i++) {
      final pkt = _packets[i];
      if (pkt == null) {
        _packets.clear();
        return null;
      }
      allBytes.addAll(pkt);
    }
    _packets.clear();

    // Decode int16 to doubles (scale factor 1000 -> g units)
    final accelX = <double>[];
    final accelY = <double>[];
    final accelZ = <double>[];

    for (int i = 0; i < _expectedSamples && (i * 6 + 5) < allBytes.length; i++) {
      final offset = i * 6;
      final x = _readInt16(allBytes, offset) / 1000.0;
      final y = _readInt16(allBytes, offset + 2) / 1000.0;
      final z = _readInt16(allBytes, offset + 4) / 1000.0;
      accelX.add(x);
      accelY.add(y);
      accelZ.add(z);
    }

    return RawAccelData(
      accelX: accelX,
      accelY: accelY,
      accelZ: accelZ,
      sampleCount: accelX.length,
    );
  }

  int _readInt16(List<int> bytes, int offset) {
    final val = bytes[offset] | (bytes[offset + 1] << 8);
    return val >= 0x8000 ? val - 0x10000 : val;
  }

  void reset() {
    _packets.clear();
    _firstPacketTime = null;
  }
}

/// Clean raw BLE bytes: strip null bytes and trim whitespace.
String cleanBleBytes(List<int> raw) {
  final cleaned = raw.where((b) => b != 0).toList();
  return String.fromCharCodes(cleaned).trim();
}

/// Parse a cleaned JSON string from BLE into the appropriate data type.
/// [charUuid] is used to determine which characteristic sent the data.
BleParseResult parseBleJson(String jsonStr, String charUuid) {
  if (jsonStr.isEmpty) return BleParseError('empty');

  // Check for truncated JSON
  if (!jsonStr.endsWith('}')) {
    return BleParseError('truncated');
  }

  final dynamic data;
  try {
    data = json.decode(jsonStr);
  } catch (e) {
    return BleParseError('invalid_json: $e');
  }
  if (data == null) return BleParseError('null_data');

  // IMU: UUID ends with 26a8
  if (charUuid.endsWith('26a8') || charUuid.contains('b26a8')) {
    return ImuData(
      x: (data['x'] as num?)?.toDouble() ?? 0.0,
      y: (data['y'] as num?)?.toDouble() ?? 0.0,
      z: (data['z'] as num?)?.toDouble() ?? 0.0,
      vib: (data['vib'] as num?)?.toDouble() ?? 0.0,
      ppv: (data['ppv'] as num?)?.toDouble() ?? 0.0,
      rms: (data['rms'] as num?)?.toDouble() ?? 0.0,
      freq: (data['freq'] as num?)?.toDouble() ?? 0.0,
      crest: (data['crest'] as num?)?.toDouble() ?? 0.0,
      cent: (data['cent'] as num?)?.toDouble() ?? 0.0,
      kurt: (data['kurt'] as num?)?.toDouble() ?? 0.0,
      stalta: (data['stalta'] as num?)?.toDouble() ?? 0.0,
      // v4.0 firmware fields (backward compatible - default to 0 if missing)
      arias: (data['arias'] as num?)?.toDouble() ?? 0.0,
      cav: (data['cav'] as num?)?.toDouble() ?? 0.0,
      temp: (data['temp'] as num?)?.toDouble() ?? 0.0,
      dwt1: (data['dwt1'] as num?)?.toDouble() ?? 0.0,
      dwt2: (data['dwt2'] as num?)?.toDouble() ?? 0.0,
      dwt3: (data['dwt3'] as num?)?.toDouble() ?? 0.0,
      // v5.0 firmware field (backward compatible)
      peak: (data['peak'] as num?)?.toDouble() ?? 0.0,
      // v5.1 firmware field: sequence number for missed-packet detection
      seq: (data['seq'] as num?)?.toInt() ?? 0,
    );
  }

  // Moisture: UUID ends with 26a9
  if (charUuid.endsWith('26a9') || charUuid.contains('b26a9')) {
    return MoistureData(
      percent: (data['percent'] as num?)?.toInt() ?? 0,
      raw: (data['raw'] as num?)?.toInt() ?? 0,
      vib: (data['vib'] as num?)?.toDouble(),
    );
  }

  // Alert: UUID ends with 26aa
  if (charUuid.endsWith('26aa') || charUuid.contains('b26aa')) {
    return AlertBleData(
      level: data['level'] as String? ?? 'safe',
      message: data['message'] as String? ?? '',
      type: data['type'] as String? ?? 'none',
    );
  }

  // Battery: UUID ends with 26ab (v4.1)
  if (charUuid.endsWith('26ab') || charUuid.contains('b26ab')) {
    return BatteryData(
      voltage: (data['voltage'] as num?)?.toDouble() ?? 0.0,
      percent: (data['percent'] as num?)?.toInt() ?? 0,
      charging: data['charging'] as bool? ?? false,
    );
  }

  return BleParseError('unknown_uuid: $charUuid');
}

/// Returns true if the BLE device name matches the AncientVision prefix.
/// Use this to filter scan results before connecting.
bool isAncientVisionDevice(String? deviceName) {
  if (deviceName == null || deviceName.isEmpty) return false;
  return deviceName.toLowerCase().startsWith('ancientvision') ||
      deviceName.toLowerCase().startsWith('ancient_vision') ||
      deviceName.toLowerCase().startsWith('av_sensor');
}
