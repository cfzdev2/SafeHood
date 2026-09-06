enum CameraRecordingStorage { cloud, sdCard, unknown }

enum CameraRecordingTrigger {
  motion,
  person,
  vehicle,
  sound,
  manual,
  continuous,
  unknown,
}

class CameraRecording {
  final String id;
  final String cameraId;

  final DateTime startedAt;
  final Duration duration;

  final CameraRecordingStorage storage;
  final CameraRecordingTrigger trigger;

  final Uri? thumbnailUri;

  const CameraRecording({
    required this.id,
    required this.cameraId,
    required this.startedAt,
    required this.duration,
    required this.storage,
    required this.trigger,
    this.thumbnailUri,
  });
}

class CameraRecordingPage {
  final List<CameraRecording> recordings;
  final String? nextPageToken;

  const CameraRecordingPage({required this.recordings, this.nextPageToken});

  bool get hasMore => nextPageToken != null && nextPageToken!.trim().isNotEmpty;
}
