import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/domain/camera_notification_settings.dart';

void main() {
  group('CameraNotificationSettings', () {
    test('domyślnie włącza wszystkie powiadomienia', () {
      const settings = CameraNotificationSettings();

      expect(settings.enabled, isTrue);
      expect(settings.motionEnabled, isTrue);
      expect(settings.personEnabled, isTrue);
      expect(settings.vehicleEnabled, isTrue);
      expect(settings.soundEnabled, isTrue);
      expect(settings.cooldownSeconds, 0);
    });

    test('odczytuje ustawienia z mapy', () {
      final settings = CameraNotificationSettings.fromMap({
        'enabled': true,
        'motion': false,
        'person': true,
        'vehicle': false,
        'sound': false,
        'cooldownSeconds': 300,
      });

      expect(settings.enabled, isTrue);
      expect(settings.motionEnabled, isFalse);
      expect(settings.personEnabled, isTrue);
      expect(settings.vehicleEnabled, isFalse);
      expect(settings.soundEnabled, isFalse);
      expect(settings.cooldownSeconds, 300);
    });

    test('używa bezpiecznych wartości dla błędnych danych', () {
      final settings = CameraNotificationSettings.fromMap({
        'enabled': 'false',
        'motion': null,
        'person': 0,
        'cooldownSeconds': 31,
      });

      expect(settings.enabled, isTrue);
      expect(settings.motionEnabled, isTrue);
      expect(settings.personEnabled, isTrue);
      expect(settings.vehicleEnabled, isTrue);
      expect(settings.soundEnabled, isTrue);
      expect(settings.cooldownSeconds, 0);
    });

    test('używa wartości domyślnych bez mapy', () {
      final settings = CameraNotificationSettings.fromMap(null);

      expect(settings.enabled, isTrue);
      expect(settings.motionEnabled, isTrue);
      expect(settings.personEnabled, isTrue);
      expect(settings.vehicleEnabled, isTrue);
      expect(settings.soundEnabled, isTrue);
      expect(settings.cooldownSeconds, 0);
    });

    test('copyWith zmienia tylko wybrane ustawienia', () {
      const original = CameraNotificationSettings(
        motionEnabled: false,
        personEnabled: false,
      );

      final updated = original.copyWith(
        personEnabled: true,
        soundEnabled: false,
        cooldownSeconds: 60,
      );

      expect(updated.enabled, isTrue);
      expect(updated.motionEnabled, isFalse);
      expect(updated.personEnabled, isTrue);
      expect(updated.vehicleEnabled, isTrue);
      expect(updated.soundEnabled, isFalse);
      expect(updated.cooldownSeconds, 60);
    });

    test('toMap zapisuje prawidłowe nazwy pól', () {
      const settings = CameraNotificationSettings(
        enabled: false,
        motionEnabled: true,
        personEnabled: false,
        vehicleEnabled: true,
        soundEnabled: false,
        cooldownSeconds: 900,
      );

      expect(settings.toMap(), {
        'enabled': false,
        'motion': true,
        'person': false,
        'vehicle': true,
        'sound': false,
        'cooldownSeconds': 900,
      });
    });
  });
}
