import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';

class DebugSafeArkCameraProvider
    implements
        CameraProvider,
        CameraTalkController,
        CameraPtzController,
        CameraFloodlightController,
        CameraSirenController {
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
    await _simulateRequest();

    debugPrint(
      'SAFEARK DEBUG [${camera.id}]: '
      'snapshot',
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

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    await _stateController.close();
  }
}
