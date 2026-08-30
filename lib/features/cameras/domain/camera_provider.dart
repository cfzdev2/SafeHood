import 'camera.dart';

class CameraCapabilities {
  final bool supportsLive;
  final bool supportsAudio;
  final bool supportsTalk;
  final bool supportsMotionDetection;
  final bool supportsPersonDetection;
  final bool supportsRecordings;
  final bool supportsSnapshot;
  final bool supportsPtz;

  const CameraCapabilities({
    required this.supportsLive,
    required this.supportsAudio,
    required this.supportsTalk,
    required this.supportsMotionDetection,
    required this.supportsPersonDetection,
    required this.supportsRecordings,
    required this.supportsSnapshot,
    required this.supportsPtz,
  });
}

class CameraRuntimeState {
  final bool isOnline;
  final bool isConnecting;
  final bool isLive;
  final bool motionDetectionEnabled;

  const CameraRuntimeState({
    required this.isOnline,
    required this.isConnecting,
    required this.isLive,
    required this.motionDetectionEnabled,
  });

  factory CameraRuntimeState.fromCamera(Camera camera) {
    return CameraRuntimeState(
      isOnline: camera.isOnline,
      isConnecting: false,
      isLive: false,
      motionDetectionEnabled: camera.motionDetectionEnabled,
    );
  }

  CameraRuntimeState copyWith({
    bool? isOnline,
    bool? isConnecting,
    bool? isLive,
    bool? motionDetectionEnabled,
  }) {
    return CameraRuntimeState(
      isOnline: isOnline ?? this.isOnline,
      isConnecting: isConnecting ?? this.isConnecting,
      isLive: isLive ?? this.isLive,
      motionDetectionEnabled:
          motionDetectionEnabled ?? this.motionDetectionEnabled,
    );
  }
}

class CameraDetection {
  final String type;
  final DateTime occurredAt;
  final String source;
  final double? confidence;

  const CameraDetection({
    required this.type,
    required this.occurredAt,
    required this.source,
    this.confidence,
  });
}

/// Provider, który potrafi emitować
/// wykrycia z kamery.
///
/// Nie każda kamera/provider musi
/// implementować Events.
abstract interface class CameraDetectionSource {
  Stream<CameraDetection> watchDetections();
}

abstract interface class CameraDetectionMonitoringController {
  Future<void> startDetectionMonitoring();

  Future<void> stopDetectionMonitoring();
}

abstract class CameraProvider {
  Camera get camera;

  CameraCapabilities get capabilities;

  ///
  /// Aktualny adres strumienia LIVE.
  ///
  /// Dla ONVIF będzie to zwykle RTSP.
  /// Inny provider może później zwracać
  /// np. HLS/HTTPS.
  ///
  /// null oznacza, że provider nie ma
  /// jeszcze dostępnego źródła LIVE.
  ///
  Uri? get liveStreamUri => null;

  Stream<CameraRuntimeState> watchState();

  Future<void> connect();

  Future<void> disconnect();

  Future<void> startLive();

  Future<void> stopLive();

  Future<void> setMotionDetection(bool enabled);

  Future<void> takeSnapshot();

  Future<void> dispose();
}
