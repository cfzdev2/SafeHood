import 'dart:async';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';

class MockCameraProvider implements CameraProvider {
  @override
  final Camera camera;

  @override
  Uri? get liveStreamUri => null;

  final StreamController<CameraRuntimeState> _controller =
      StreamController<CameraRuntimeState>.broadcast();

  late CameraRuntimeState _state;

  MockCameraProvider({required this.camera}) {
    _state = CameraRuntimeState.fromCamera(camera).copyWith(isOnline: true);
  }

  @override
  CameraCapabilities get capabilities => const CameraCapabilities(
    supportsLive: true,
    supportsAudio: true,
    supportsTalk: true,
    supportsMotionDetection: true,
    supportsPersonDetection: false,
    supportsRecordings: true,
    supportsSnapshot: true,
    supportsPtz: false,
  );

  @override
  Stream<CameraRuntimeState> watchState() async* {
    yield _state;
    yield* _controller.stream;
  }

  void _updateState(CameraRuntimeState state) {
    _state = state;

    if (!_controller.isClosed) {
      _controller.add(state);
    }
  }

  @override
  Future<void> connect() async {
    if (!_state.isOnline) {
      return;
    }

    _updateState(_state.copyWith(isConnecting: true));

    await Future<void>.delayed(const Duration(milliseconds: 500));

    _updateState(_state.copyWith(isConnecting: false));
  }

  @override
  Future<void> disconnect() async {
    _updateState(_state.copyWith(isConnecting: false, isLive: false));
  }

  @override
  Future<void> startLive() async {
    if (!_state.isOnline) {
      return;
    }

    _updateState(_state.copyWith(isConnecting: true));

    await Future<void>.delayed(const Duration(milliseconds: 500));

    _updateState(_state.copyWith(isConnecting: false, isLive: true));
  }

  @override
  Future<void> stopLive() async {
    _updateState(_state.copyWith(isLive: false, isConnecting: false));
  }

  @override
  Future<void> setMotionDetection(bool enabled) async {
    _updateState(_state.copyWith(motionDetectionEnabled: enabled));
  }

  @override
  Future<void> takeSnapshot() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}
