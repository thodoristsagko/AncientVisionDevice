import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/utils/ble_parser.dart';

void main() {
  group('cleanBleBytes', () {
    test('strips null bytes', () {
      final raw = [0x7B, 0x7D, 0x00, 0x00]; // "{}" + null bytes
      expect(cleanBleBytes(raw), '{}');
    });

    test('trims whitespace', () {
      final raw = ' {"x":1} '.codeUnits;
      expect(cleanBleBytes(raw), '{"x":1}');
    });

    test('handles empty input', () {
      expect(cleanBleBytes([]), '');
    });

    test('handles all-null input', () {
      expect(cleanBleBytes([0, 0, 0]), '');
    });
  });

  group('parseBleJson - IMU', () {
    const imuUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

    test('parses v3.0 IMU payload', () {
      const json =
          '{"x":0.012,"y":-0.003,"z":9.810,"vib":0.0042,"ppv":1.5,"rms":0.0031,"freq":12.5,"crest":3.2,"cent":15.0,"kurt":2.10,"stalta":1.50}';
      final result = parseBleJson(json, imuUuid);
      expect(result, isA<ImuData>());
      final imu = result as ImuData;
      expect(imu.x, closeTo(0.012, 0.001));
      expect(imu.y, closeTo(-0.003, 0.001));
      expect(imu.z, closeTo(9.810, 0.001));
      expect(imu.vib, closeTo(0.0042, 0.0001));
      expect(imu.ppv, closeTo(1.5, 0.1));
      expect(imu.rms, closeTo(0.0031, 0.0001));
      expect(imu.freq, closeTo(12.5, 0.1));
      expect(imu.crest, closeTo(3.2, 0.1));
      expect(imu.cent, closeTo(15.0, 0.1));
      expect(imu.kurt, closeTo(2.10, 0.01));
      expect(imu.stalta, closeTo(1.50, 0.01));
    });

    test('parses v4.0 IMU payload (all 17 fields)', () {
      const json =
          '{"x":0.012,"y":-0.003,"z":9.810,"vib":0.0042,"ppv":1.5,"rms":0.0031,"freq":12.5,"crest":3.2,"cent":15.0,"kurt":2.10,"stalta":1.50,"arias":0.0023,"cav":0.045,"temp":24.5,"dwt1":0.0012,"dwt2":0.0008,"dwt3":0.0005}';
      final result = parseBleJson(json, imuUuid);
      expect(result, isA<ImuData>());
      final imu = result as ImuData;
      expect(imu.x, closeTo(0.012, 0.001));
      expect(imu.ppv, closeTo(1.5, 0.1));
      expect(imu.kurt, closeTo(2.10, 0.01));
      // v4.0 fields
      expect(imu.arias, closeTo(0.0023, 0.0001));
      expect(imu.cav, closeTo(0.045, 0.001));
      expect(imu.temp, closeTo(24.5, 0.1));
      expect(imu.dwt1, closeTo(0.0012, 0.0001));
      expect(imu.dwt2, closeTo(0.0008, 0.0001));
      expect(imu.dwt3, closeTo(0.0005, 0.0001));
    });

    test('parses v2.0 payload (missing v3 fields)', () {
      const json = '{"x":0.1,"y":0.2,"z":9.8,"vib":0.01,"ppv":2.0,"rms":0.005,"freq":10.0,"crest":4.0}';
      final result = parseBleJson(json, imuUuid);
      expect(result, isA<ImuData>());
      final imu = result as ImuData;
      expect(imu.cent, 0.0); // defaults to 0
      expect(imu.kurt, 0.0);
      expect(imu.stalta, 0.0);
      // v4.0 fields also default to 0
      expect(imu.arias, 0.0);
      expect(imu.cav, 0.0);
      expect(imu.temp, 0.0);
      expect(imu.dwt1, 0.0);
      expect(imu.dwt2, 0.0);
      expect(imu.dwt3, 0.0);
    });

    test('handles integer values', () {
      const json = '{"x":1,"y":2,"z":10,"vib":0}';
      final result = parseBleJson(json, imuUuid);
      expect(result, isA<ImuData>());
      final imu = result as ImuData;
      expect(imu.x, 1.0);
      expect(imu.z, 10.0);
    });
  });

  group('parseBleJson - Moisture', () {
    const moistureUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a9';

    test('parses moisture payload', () {
      const json = '{"percent":42,"raw":1850}';
      final result = parseBleJson(json, moistureUuid);
      expect(result, isA<MoistureData>());
      final m = result as MoistureData;
      expect(m.percent, 42);
      expect(m.raw, 1850);
      expect(m.vib, isNull);
    });

    test('parses moisture with vibration', () {
      const json = '{"percent":30,"raw":2000,"vib":0.005}';
      final result = parseBleJson(json, moistureUuid);
      expect(result, isA<MoistureData>());
      final m = result as MoistureData;
      expect(m.vib, closeTo(0.005, 0.001));
    });
  });

  group('parseBleJson - Alert', () {
    const alertUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26aa';

    test('parses alert payload', () {
      const json = '{"level":"critical","message":"PPV exceeds 8.0 mm/s","type":"seismic"}';
      final result = parseBleJson(json, alertUuid);
      expect(result, isA<AlertBleData>());
      final a = result as AlertBleData;
      expect(a.level, 'critical');
      expect(a.message, 'PPV exceeds 8.0 mm/s');
      expect(a.type, 'seismic');
    });

    test('handles safe alert', () {
      const json = '{"level":"safe","message":"","type":"none"}';
      final result = parseBleJson(json, alertUuid);
      expect(result, isA<AlertBleData>());
      final a = result as AlertBleData;
      expect(a.level, 'safe');
      expect(a.message, '');
    });
  });

  group('parseBleJson - Error cases', () {
    const imuUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

    test('returns error for empty string', () {
      final result = parseBleJson('', imuUuid);
      expect(result, isA<BleParseError>());
      expect((result as BleParseError).reason, 'empty');
    });

    test('returns error for truncated JSON', () {
      final result = parseBleJson('{"x":1.0,"y":2', imuUuid);
      expect(result, isA<BleParseError>());
      expect((result as BleParseError).reason, 'truncated');
    });

    test('returns error for invalid JSON', () {
      final result = parseBleJson('{not json}', imuUuid);
      expect(result, isA<BleParseError>());
      expect((result as BleParseError).reason, startsWith('invalid_json'));
    });

    test('returns error for unknown UUID', () {
      final result = parseBleJson('{"x":1}', 'unknown-uuid');
      expect(result, isA<BleParseError>());
      expect((result as BleParseError).reason, startsWith('unknown_uuid'));
    });
  });
}
