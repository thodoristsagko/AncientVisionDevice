import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/settings_service.dart';

void main() {
  group('AppSettings defaults', () {
    test('default values are correct', () {
      final settings = AppSettings();
      expect(settings.themeMode, AppThemeMode.dark);
      expect(settings.accentColorIndex, 0);
      expect(settings.fontSize, 1.0);
      expect(settings.compactMode, false);
      expect(settings.measurementSystem, MeasurementSystem.metric);
      expect(settings.dateFormat, DateFormatPreference.dmy);
      expect(settings.languageCode, 'en');
      expect(settings.autoSync, true);
      expect(settings.offlineMode, false);
      expect(settings.compressImages, true);
      expect(settings.imageQuality, 85);
      expect(settings.notificationsEnabled, true);
      expect(settings.nightMode, false);
      expect(settings.lockedSensorMac, '');
      expect(settings.maxPhotosPerScan, 50);
    });
  });

  group('AppSettings toJson/fromJson round-trip', () {
    test('default settings survive round-trip', () {
      final original = AppSettings();
      final json = original.toJson();
      final restored = AppSettings.fromJson(json);

      expect(restored.themeMode, original.themeMode);
      expect(restored.accentColorIndex, original.accentColorIndex);
      expect(restored.fontSize, original.fontSize);
      expect(restored.compactMode, original.compactMode);
      expect(restored.measurementSystem, original.measurementSystem);
      expect(restored.dateFormat, original.dateFormat);
      expect(restored.languageCode, original.languageCode);
      expect(restored.autoSync, original.autoSync);
      expect(restored.offlineMode, original.offlineMode);
      expect(restored.imageQuality, original.imageQuality);
      expect(restored.nightMode, original.nightMode);
      expect(restored.lockedSensorMac, original.lockedSensorMac);
      expect(restored.maxPhotosPerScan, original.maxPhotosPerScan);
    });

    test('custom settings survive round-trip', () {
      final original = AppSettings(
        themeMode: AppThemeMode.light,
        accentColorIndex: 3,
        fontSize: 1.5,
        compactMode: true,
        measurementSystem: MeasurementSystem.imperial,
        dateFormat: DateFormatPreference.ymd,
        languageCode: 'el',
        autoSync: false,
        offlineMode: true,
        imageQuality: 50,
        nightMode: true,
        lockedSensorMac: 'AA:BB:CC:DD:EE:FF',
        maxPhotosPerScan: 100,
      );
      final json = original.toJson();
      final restored = AppSettings.fromJson(json);

      expect(restored.themeMode, AppThemeMode.light);
      expect(restored.accentColorIndex, 3);
      expect(restored.fontSize, 1.5);
      expect(restored.compactMode, true);
      expect(restored.measurementSystem, MeasurementSystem.imperial);
      expect(restored.dateFormat, DateFormatPreference.ymd);
      expect(restored.languageCode, 'el');
      expect(restored.autoSync, false);
      expect(restored.offlineMode, true);
      expect(restored.imageQuality, 50);
      expect(restored.nightMode, true);
      expect(restored.lockedSensorMac, 'AA:BB:CC:DD:EE:FF');
      expect(restored.maxPhotosPerScan, 100);
    });

    test('fromJson handles missing fields with defaults', () {
      final settings = AppSettings.fromJson({});
      expect(settings.themeMode, AppThemeMode.dark);
      expect(settings.fontSize, 1.0);
      expect(settings.languageCode, 'en');
      expect(settings.imageQuality, 85);
      expect(settings.nightMode, false);
    });

    test('fromJson handles unknown enum values', () {
      final settings = AppSettings.fromJson({
        'themeMode': 'nonexistent',
        'measurementSystem': 'alien',
        'dateFormat': 'martian',
      });
      expect(settings.themeMode, AppThemeMode.dark);
      expect(settings.measurementSystem, MeasurementSystem.metric);
      expect(settings.dateFormat, DateFormatPreference.dmy);
    });
  });

  group('AppSettings copyWith', () {
    test('copies with single field changed', () {
      final original = AppSettings();
      final modified = original.copyWith(nightMode: true);
      expect(modified.nightMode, true);
      expect(modified.themeMode, original.themeMode); // unchanged
      expect(modified.fontSize, original.fontSize); // unchanged
    });

    test('copies with multiple fields changed', () {
      final original = AppSettings();
      final modified = original.copyWith(
        fontSize: 2.0,
        languageCode: 'el',
        lockedSensorMac: '11:22:33:44:55:66',
      );
      expect(modified.fontSize, 2.0);
      expect(modified.languageCode, 'el');
      expect(modified.lockedSensorMac, '11:22:33:44:55:66');
      expect(modified.nightMode, original.nightMode);
    });
  });
}
