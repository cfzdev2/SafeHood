import 'camera.dart';
import 'camera_recording.dart';

enum CameraPtzDirection { up, down, left, right }

class CameraCapabilities {
  final bool supportsLive;
  final bool supportsAudio;
  final bool supportsTalk;
  final bool supportsMotionDetection;
  final bool supportsPersonDetection;
  final bool supportsRecordings;
  final bool supportsSnapshot;
  final bool supportsPtz;
  final bool supportsFloodlight;
  final bool supportsSiren;

  const CameraCapabilities({
    required this.supportsLive,
    required this.supportsAudio,
    required this.supportsTalk,
    required this.supportsMotionDetection,
    required this.supportsPersonDetection,
    required this.supportsRecordings,
    required this.supportsSnapshot,
    required this.supportsPtz,
    this.supportsFloodlight = false,
    this.supportsSiren = false,
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

/// Provider emitujący wykrycia kamery.
abstract interface class CameraDetectionSource {
  Stream<CameraDetection> watchDetections();
}

/// Sterowanie uruchamianiem monitoringu
/// zdarzeń kamery.
abstract interface class CameraDetectionMonitoringController {
  Future<void> startDetectionMonitoring();

  Future<void> stopDetectionMonitoring();
}

/// Opcjonalna obsługa rozmowy
/// dwukierunkowej.
abstract interface class CameraTalkController {
  Future<void> startTalk();

  Future<void> stopTalk();
}

/// Opcjonalna obsługa obrotu
/// i pochylenia kamery.
abstract interface class CameraPtzController {
  Future<void> movePtz(CameraPtzDirection direction);

  Future<void> stopPtz();
}

/// Opcjonalna obsługa reflektora.
abstract interface class CameraFloodlightController {
  Future<void> setFloodlight(bool enabled);
}

/// Opcjonalna obsługa syreny.
abstract interface class CameraSirenController {
  Future<void> setSiren(bool enabled);
}

/// Opcjonalne źródło nagrań
/// chmurowych lub z karty SD.
abstract interface class CameraRecordingsSource {
  Future<CameraRecordingPage> loadRecordings({
    DateTime? from,
    DateTime? to,
    String? pageToken,
    int limit = 30,
  });

  /// Pobiera aktualny adres odtwarzania.
  ///
  /// Adres może być tymczasowy, dlatego
  /// pobieramy go dopiero po wybraniu
  /// konkretnego nagrania.
  Future<Uri> getRecordingPlaybackUri(CameraRecording recording);
}

abstract class CameraProvider {
  Camera get camera;

  CameraCapabilities get capabilities;

  /// Aktualny adres strumienia LIVE.
  ///
  /// Dla ONVIF będzie to zwykle RTSP.
  /// Provider chmurowy może zwrócić
  /// między innymi HLS albo WebRTC.
  ///
  /// null oznacza brak dostępnego
  /// źródła LIVE.
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
