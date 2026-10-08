import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/camera_events/domain/camera_event.dart';
import 'package:safehood/features/cameras/domain/camera.dart';

void main() {
  CameraEvent event(Map<String, dynamic> values) => CameraEvent.fromMap(
    id: 'event-1',
    map: {'ownerId': 'owner-1', 'cameraId': 'camera-1', ...values},
  );

  test('nagrywanie starszej kamery wymaga świadomego włączenia', () {
    final camera = Camera.fromMap('camera-1', {});
    expect(camera.aiRecordingEnabled, isFalse);
    final enabled = camera.copyWith(aiRecordingEnabled: true);
    expect(
      Camera.fromMap(enabled.id, enabled.toMap()).aiRecordingEnabled,
      isTrue,
    );
    expect(
      enabled.copyWith(aiRecordingEnabled: false).aiRecordingEnabled,
      isFalse,
    );
  });

  test('prywatny film zachowuje ścieżkę i rzeczywisty czas prebufora', () {
    const path = 'users/owner-1/cameraEvents/event-1/clip.mp4';
    final recorded = event({
      'clipPath': path,
      'clipDurationMillis': 15000,
      'clipPrebufferMillis': 5000,
    });
    expect(recorded.hasClip, isTrue);
    expect(recorded.privateClipPath, path);
    final restored = CameraEvent.fromMap(
      id: recorded.id,
      map: recorded.toMap(),
    );
    expect(restored.clipDurationMillis, 15000);
    expect(restored.clipPrebufferMillis, 5000);
    expect(
      restored.copyWith(status: CameraEventStatus.viewed).privateClipPath,
      path,
    );
  });

  test('ścieżka filmu nie może wskazywać innego właściciela ani zdarzenia', () {
    for (final path in [
      'users/other/cameraEvents/event-1/clip.mp4',
      'users/owner-1/cameraEvents/other/clip.mp4',
      'users/owner-1/cameraEvents/event-1/snapshot.jpg',
      'https://example.com/clip.mp4',
    ]) {
      expect(event({'clipPath': path}).privateClipPath, isNull);
      expect(event({'clipPath': path}).hasClip, isFalse);
    }
  });

  test('starsze zdarzenia i nagrania pozostają zgodne', () {
    expect(event({}).hasClip, isFalse);
    expect(event({}).clipPrebufferMillis, isNull);
    expect(event({'clipUrl': 'https://example.com/old.mp4'}).hasClip, isTrue);
  });
}
