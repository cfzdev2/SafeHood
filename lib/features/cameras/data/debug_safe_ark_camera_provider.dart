import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/camera.dart';
import '../domain/camera_recording.dart';
import '../domain/camera_provider.dart';
import '../domain/camera_snapshot.dart';

class DebugSafeArkCameraProvider
    implements
        CameraProvider,
        CameraTalkController,
        CameraPtzController,
        CameraFloodlightController,
        CameraSirenController,
        CameraRecordingsSource,
        CameraSnapshotSource {
  static const _liveStreamUrl = String.fromEnvironment(
    'SAFEHOOD_DEBUG_RTSP_URL',
    defaultValue: 'rtsp://192.168.1.10:8554/fake-stream',
  );

  @override
  final Camera camera;

  final StreamController<CameraRuntimeState> _stateController =
      StreamController<CameraRuntimeState>.broadcast();

  late CameraRuntimeState _state;

  bool _disposed = false;
  bool _talking = false;
  bool _floodlightEnabled = false;
  bool _sirenEnabled = false;

  DebugSafeArkCameraProvider({required this.camera}) {
    _state = CameraRuntimeState.fromCamera(
      camera,
    ).copyWith(isOnline: true, isConnecting: false, isLive: false);
  }

  @override
  CameraCapabilities get capabilities => const CameraCapabilities(
    supportsLive: true,
    supportsAudio: true,
    supportsTalk: true,
    supportsMotionDetection: true,
    supportsPersonDetection: true,
    supportsRecordings: true,
    supportsSnapshot: true,
    supportsPtz: true,
    supportsFloodlight: true,
    supportsSiren: true,
  );

  @override
  Uri? get liveStreamUri => Uri.parse(_liveStreamUrl);
  static const _mediaBaseUrl = String.fromEnvironment(
    'SAFEHOOD_DEBUG_CAMERA_HTTP_URL',
    defaultValue: 'http://192.168.1.10:8899',
  );

  @override
  Stream<CameraRuntimeState> watchState() async* {
    yield _state;
    yield* _stateController.stream;
  }

  void _updateState(CameraRuntimeState state) {
    _state = state;

    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  Future<void> _simulateRequest() {
    return Future<void>.delayed(const Duration(milliseconds: 250));
  }

  @override
  Future<void> connect() async {
    if (_disposed) {
      return;
    }

    _updateState(_state.copyWith(isOnline: true, isConnecting: true));

    await _simulateRequest();

    if (_disposed) {
      return;
    }

    _updateState(_state.copyWith(isOnline: true, isConnecting: false));

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'połączono',
    );
  }

  @override
  Future<void> disconnect() async {
    _updateState(_state.copyWith(isConnecting: false, isLive: false));

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'rozłączono',
    );
  }

  @override
  Future<void> startLive() async {
    if (_disposed) {
      return;
    }

    _updateState(_state.copyWith(isOnline: true, isConnecting: true));

    await _simulateRequest();

    if (_disposed) {
      return;
    }

    _updateState(
      _state.copyWith(isOnline: true, isConnecting: false, isLive: true),
    );

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'LIVE uruchomione',
    );
  }

  @override
  Future<void> stopLive() async {
    _updateState(_state.copyWith(isLive: false, isConnecting: false));

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'LIVE zatrzymane',
    );
  }

  @override
  Future<void> setMotionDetection(bool enabled) async {
    await _simulateRequest();

    if (_disposed) {
      return;
    }

    _updateState(_state.copyWith(motionDetectionEnabled: enabled));

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'motion = $enabled',
    );
  }

  @override
  Future<void> takeSnapshot() async {
    await captureSnapshot();
  }

  @override
  Future<CameraSnapshot> captureSnapshot() async {
    if (_disposed) {
      throw StateError('Provider kamery został zamknięty.');
    }

    await _simulateRequest();

    final capturedAt = DateTime.now();

    final snapshotId =
        'debug-snapshot-'
        '${capturedAt.millisecondsSinceEpoch}';

    final imageUri = Uri.parse(
      '$_mediaBaseUrl/snapshot.png',
    ).replace(queryParameters: {'event': snapshotId});

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'snapshot = $imageUri',
    );

    return CameraSnapshot(
      id: snapshotId,
      cameraId: camera.id,
      capturedAt: capturedAt,
      imageUri: imageUri,
    );
  }

  @override
  Future<void> startTalk() async {
    await _simulateRequest();

    _talking = true;

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'talk = $_talking',
    );
  }

  @override
  Future<void> stopTalk() async {
    _talking = false;

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'talk = $_talking',
    );
  }

  @override
  Future<void> movePtz(CameraPtzDirection direction) async {
    await _simulateRequest();

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'PTZ = ${direction.name}',
    );
  }

  @override
  Future<void> stopPtz() async {
    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'PTZ stop',
    );
  }

  @override
  Future<void> setFloodlight(bool enabled) async {
    await _simulateRequest();

    _floodlightEnabled = enabled;

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'floodlight = '
      '$_floodlightEnabled',
    );
  }

  @override
  Future<void> setSiren(bool enabled) async {
    await _simulateRequest();

    _sirenEnabled = enabled;

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'siren = $_sirenEnabled',
    );
  }

  Uri _snapshotUri(String recordingId) {
    return Uri.parse(
      '$_mediaBaseUrl/snapshot.png',
    ).replace(queryParameters: {'recording': recordingId});
  }

  @override
  Future<CameraRecordingPage> loadRecordings({
    DateTime? from,
    DateTime? to,
    String? pageToken,
    int limit = 30,
  }) async {
    if (_disposed) {
      throw StateError('Provider kamery został zamknięty.');
    }

    await _simulateRequest();

    final now = DateTime.now();

    final allRecordings = <CameraRecording>[
      CameraRecording(
        id: 'debug-recording-person-1',
        cameraId: camera.id,
        startedAt: now.subtract(const Duration(minutes: 4)),
        duration: const Duration(seconds: 18),
        storage: CameraRecordingStorage.cloud,
        trigger: CameraRecordingTrigger.person,
        thumbnailUri: _snapshotUri('debug-recording-person-1'),
      ),
      CameraRecording(
        id: 'debug-recording-motion-1',
        cameraId: camera.id,
        startedAt: now.subtract(const Duration(minutes: 37)),
        duration: const Duration(seconds: 22),
        storage: camera.hasSdCard
            ? CameraRecordingStorage.sdCard
            : CameraRecordingStorage.cloud,
        trigger: CameraRecordingTrigger.motion,
        thumbnailUri: _snapshotUri('debug-recording-motion-1'),
      ),
      CameraRecording(
        id: 'debug-recording-vehicle-1',
        cameraId: camera.id,
        startedAt: now.subtract(const Duration(hours: 2)),
        duration: const Duration(seconds: 35),
        storage: CameraRecordingStorage.cloud,
        trigger: CameraRecordingTrigger.vehicle,
        thumbnailUri: _snapshotUri('debug-recording-vehicle-1'),
      ),
      CameraRecording(
        id: 'debug-recording-motion-2',
        cameraId: camera.id,
        startedAt: now.subtract(const Duration(days: 1)),
        duration: const Duration(seconds: 47),
        storage: camera.hasSdCard
            ? CameraRecordingStorage.sdCard
            : CameraRecordingStorage.cloud,
        trigger: CameraRecordingTrigger.motion,
        thumbnailUri: _snapshotUri('debug-recording-motion-2'),
      ),
    ];

    final filtered = allRecordings.where((recording) {
      if (from != null && recording.startedAt.isBefore(from)) {
        return false;
      }

      if (to != null && recording.startedAt.isAfter(to)) {
        return false;
      }

      return true;
    }).toList();

    final normalizedToken = pageToken?.trim() ?? '';

    final parsedOffset = normalizedToken.isEmpty
        ? 0
        : int.tryParse(normalizedToken);

    if (parsedOffset == null || parsedOffset < 0) {
      throw StateError('Nieprawidłowy token strony nagrań.');
    }

    final normalizedLimit = limit < 1
        ? 1
        : limit > 100
        ? 100
        : limit;

    final start = parsedOffset > filtered.length
        ? filtered.length
        : parsedOffset;

    final requestedEnd = start + normalizedLimit;

    final end = requestedEnd > filtered.length ? filtered.length : requestedEnd;

    final recordings = filtered.sublist(start, end);

    final nextPageToken = end < filtered.length ? '$end' : null;

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'pobrano ${recordings.length} nagrań',
    );

    return CameraRecordingPage(
      recordings: recordings,
      nextPageToken: nextPageToken,
    );
  }

  @override
  Future<Uri> getRecordingPlaybackUri(CameraRecording recording) async {
    if (_disposed) {
      throw StateError('Provider kamery został zamknięty.');
    }

    if (recording.cameraId != camera.id) {
      throw StateError('Nagranie nie należy do tej kamery.');
    }

    await _simulateRequest();

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'odtwarzanie ${recording.id}',
    );

    return Uri.parse(
      '$_mediaBaseUrl/clip.mp4',
    ).replace(queryParameters: {'recording': recording.id});
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    await _stateController.close();
  }
}
