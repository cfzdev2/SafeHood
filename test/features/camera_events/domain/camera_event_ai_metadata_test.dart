import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/camera_events/domain/camera_event.dart';
import 'package:safehood/features/camera_events/domain/camera_event_ai_metadata.dart';

void main() {
  final firstSeenAt = DateTime.utc(2026, 10, 9, 12);
  final lastSeenAt = firstSeenAt.add(const Duration(milliseconds: 1500));

  Map<String, dynamic> valid() => {
    'schemaVersion': 1,
    'totalObjects': 2,
    'personCount': 1,
    'vehicleCount': 1,
    'classCounts': {'person': 1, 'bus': 1},
    'maximumConfidence': 0.94,
    'firstSeenAt': Timestamp.fromDate(firstSeenAt),
    'lastSeenAt': Timestamp.fromDate(lastSeenAt),
    'detectionFrameCount': 7,
    'modelIds': ['yolox-nano-coco-c789161e'],
  };

  test('odczytuje pełne i spójne podsumowanie AI', () {
    final metadata = CameraEventAiMetadata.tryParse(valid());
    expect(metadata, isNotNull);
    expect(metadata!.totalObjects, 2);
    expect(metadata.personCount, 1);
    expect(metadata.vehicleCount, 1);
    expect(metadata.classCounts, {'person': 1, 'bus': 1});
    expect(metadata.confidencePercent, 94);
    expect(metadata.activityDuration, const Duration(milliseconds: 1500));
    expect(metadata.detectionFrameCount, 7);
  });

  test('zachowuje metadane podczas serializacji i copyWith zdarzenia', () {
    final event = CameraEvent.fromMap(
      id: 'event-1',
      map: {
        'ownerId': 'owner-1',
        'cameraId': 'camera-1',
        'aiMetadata': valid(),
      },
    );
    expect(event.aiMetadata?.classCounts['bus'], 1);
    final restored = CameraEvent.fromMap(id: event.id, map: event.toMap());
    expect(restored.aiMetadata?.totalObjects, 2);
    expect(
      event.copyWith(status: CameraEventStatus.viewed).aiMetadata?.modelIds,
      ['yolox-nano-coco-c789161e'],
    );
  });

  test('starsze zdarzenie bez metadanych pozostaje zgodne', () {
    final event = CameraEvent.fromMap(
      id: 'event-1',
      map: {'ownerId': 'owner-1', 'cameraId': 'camera-1'},
    );
    expect(event.aiMetadata, isNull);
  });

  test('odrzuca niespójne lub nieobsługiwane podsumowanie', () {
    for (final value in [
      {...valid(), 'schemaVersion': 2},
      {...valid(), 'totalObjects': 3},
      {...valid(), 'personCount': 2},
      {...valid(), 'classCounts': {'person': 1, 'dog': 1}},
      {...valid(), 'maximumConfidence': 1.1},
      {
        ...valid(),
        'lastSeenAt': Timestamp.fromDate(
          firstSeenAt.subtract(const Duration(seconds: 1)),
        ),
      },
      {...valid(), 'modelIds': ['unknown-model']},
      {...valid(), 'modelIds': ['yolox-nano-coco-deadbeef']},
    ]) {
      expect(CameraEventAiMetadata.tryParse(value), isNull);
    }
  });
}
