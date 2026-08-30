import 'dart:async';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';

class UnavailableCameraProvider implements CameraProvider {
  @override
  final Camera camera;

  @override
  Uri? get liveStreamUri => null;

  final String reason;

  late CameraRuntimeState _state;

  final StreamController<CameraRuntimeState> _stateController =
      StreamController<CameraRuntimeState>.broadcast();

  UnavailableCameraProvider({required this.camera, required this.reason}) {
    _state = CameraRuntimeState.fromCamera(
      camera,
    ).copyWith(isOnline: false, isConnecting: false, isLive: false);
  }

  @override
  CameraCapabilities get capabilities => const CameraCapabilities(
    supportsLive: false,
    supportsAudio: false,
    supportsTalk: false,
    supportsMotionDetection: false,
    supportsPersonDetection: false,
    supportsRecordings: false,
    supportsSnapshot: false,
    supportsPtz: false,
  );

  @override
  Stream<CameraRuntimeState> watchState() async* {
    yield _state;
    yield* _stateController.stream;
  }

  @override
  Future<void> connect() async {
    _emit(_state.copyWith(isOnline: false, isConnecting: false, isLive: false));
  }

  @override
  Future<void> disconnect() async {
    _emit(_state.copyWith(isOnline: false, isConnecting: false, isLive: false));
  }

  @override
  Future<void> startLive() async {}

  @override
  Future<void> stopLive() async {
    _emit(_state.copyWith(isLive: false));
  }

  @override
  Future<void> setMotionDetection(bool enabled) async {}

  @override
  Future<void> takeSnapshot() async {}

  void _emit(CameraRuntimeState state) {
    _state = state;

    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  @override
  Future<void> dispose() async {
    await _stateController.close();
  }
}
