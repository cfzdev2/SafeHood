import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import 'local_camera_connection.dart';
import 'local_camera_store.dart';

class RtspCameraProvider extends CameraProvider {
  RtspCameraProvider({required this.camera})
    : _state = CameraRuntimeState.fromCamera(camera);

  @override
  final Camera camera;
  final _changes = StreamController<CameraRuntimeState>.broadcast();
  CameraRuntimeState _state;
  Uri? _uri;

  @override
  Uri? get liveStreamUri => _uri;

  @override
  CameraCapabilities get capabilities => const CameraCapabilities(
    supportsLive: true,
    supportsAudio: true,
    supportsTalk: false,
    supportsMotionDetection: false,
    supportsPersonDetection: false,
    supportsRecordings: false,
    supportsSnapshot: false,
    supportsPtz: false,
  );

  void _emit(CameraRuntimeState state) {
    _state = state;
    if (!_changes.isClosed) _changes.add(state);
  }

  @override
  Stream<CameraRuntimeState> watchState() async* {
    yield _state;
    yield* _changes.stream;
  }

  @override
  Future<void> connect() async {
    _emit(_state.copyWith(isConnecting: true, isOnline: false, isLive: false));
    try {
      final settings = await const LocalCameraConnectionStore().read(camera.id);
      final address = settings.playbackUri;
      if (address == null) {
        throw const CameraConnectionIssue(
          'Dodaj adres RTSP w ustawieniach kamery. Adres jest zapisany tylko na tym telefonie.',
          retryable: false,
        );
      }
      final uid = settings.reolinkUid;
      _uri = uid != null && defaultTargetPlatform == TargetPlatform.android
          ? await const LocalCameraPlayer().refreshReolink(uid, address)
          : address;
    } finally {
      _emit(_state.copyWith(isConnecting: false));
    }
  }

  @override
  Future<void> startLive() async =>
      _emit(_state.copyWith(isOnline: true, isLive: true));

  @override
  Future<void> stopLive() async => _emit(_state.copyWith(isLive: false));

  @override
  Future<void> disconnect() async {
    _uri = null;
    _emit(_state.copyWith(isOnline: false, isLive: false));
  }

  @override
  Future<void> dispose() => _changes.close();

  @override
  Future<void> setMotionDetection(bool enabled) async {}

  @override
  Future<void> takeSnapshot() async {}
}
