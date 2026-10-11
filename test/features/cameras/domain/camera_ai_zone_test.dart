import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/domain/camera_ai_zone.dart';

void main() {
  group('CameraAiZone', () {
    test('odczytuje i zapisuje poprawną znormalizowaną strefę', () {
      final zone = CameraAiZone.tryParse({
        'left': 0.1,
        'top': 0.2,
        'width': 0.4,
        'height': 0.5,
      });

      expect(zone, isNotNull);
      expect(zone!.isValid, isTrue);
      expect(zone.right, closeTo(0.5, 0.000001));
      expect(zone.bottom, closeTo(0.7, 0.000001));
      expect(zone.toMap(), {
        'left': 0.1,
        'top': 0.2,
        'width': 0.4,
        'height': 0.5,
      });
    });

    test('odrzuca strefę poza obrazem albo mniejszą od limitu', () {
      expect(
        CameraAiZone.tryParse({
          'left': 0.9,
          'top': 0,
          'width': 0.2,
          'height': 1,
        }),
        isNull,
      );
      expect(
        CameraAiZone.tryParse({
          'left': 0,
          'top': 0,
          'width': 0.01,
          'height': 1,
        }),
        isNull,
      );
    });

    test('uszkodzony element unieważnia całą listę', () {
      final zones = CameraAiZone.parseList([
        {'left': 0, 'top': 0, 'width': 1, 'height': 1},
        {'left': '0', 'top': 0, 'width': 1, 'height': 1},
      ]);

      expect(zones, isEmpty);
      expect(
        CameraAiZone.parseList(
          List.generate(
            5,
            (_) => {'left': 0, 'top': 0, 'width': 1, 'height': 1},
          ),
        ),
        isEmpty,
      );
    });

    test('Camera zachowuje strefy w mapowaniu i copyWith', () {
      const detectionZone = CameraAiZone(
        left: 0,
        top: 0.5,
        width: 0.5,
        height: 0.5,
      );
      const ignoreZone = CameraAiZone(
        left: 0.8,
        top: 0,
        width: 0.2,
        height: 0.2,
      );
      final camera = Camera.fromMap('camera-1', {
        'aiDetectionZones': [detectionZone.toMap()],
        'aiIgnoreZones': [ignoreZone.toMap()],
      });

      expect(camera.aiDetectionZones, [detectionZone]);
      expect(camera.aiIgnoreZones, [ignoreZone]);
      expect(camera.toMap()['aiDetectionZones'], [detectionZone.toMap()]);

      final updated = camera.copyWith(aiIgnoreZones: const []);
      expect(updated.aiDetectionZones, [detectionZone]);
      expect(updated.aiIgnoreZones, isEmpty);
    });
  });
}
