import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/incidents/domain/incident.dart';

void main() {
  test('only the reporter can open the camera of an active report', () {
    final now = DateTime.utc(2026, 11, 22, 20);
    final expires = now.add(const Duration(minutes: 5));
    final incident = Incident(
      id: 'report',
      reporterId: 'owner',
      reporterName: 'Owner',
      cameraId: 'camera',
      cameraName: 'Camera',
      title: 'Report',
      createdAt: now,
      expiresAt: expires,
      status: IncidentStatus.active,
      hasRecording: false,
      participantIds: const ['owner', 'neighbor'],
    );

    expect(incident.canOpenCameraLive('owner', now), isTrue);
    expect(incident.canOpenCameraLive('neighbor', now), isFalse);
    expect(incident.canOpenCameraLive(null, now), isFalse);
    expect(incident.canOpenCameraLive('owner', expires), isFalse);
  });
}
