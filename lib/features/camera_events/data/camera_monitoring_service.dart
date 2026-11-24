import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../cameras/data/camera_provider_factory.dart';
import '../../cameras/domain/camera.dart';
import '../../cameras/domain/camera_provider.dart';
import 'camera_event_service.dart';

class CameraMonitoringService {
  CameraMonitoringService({
    this.cameraEventService,
    CameraProvider Function(Camera)? providerFactory,
    this.ingest,
  }) : _providerFactory = providerFactory ?? CameraProviderFactory.create;

  final CameraEventService? cameraEventService;
  final CameraProvider Function(Camera) _providerFactory;
  final Future<void> Function(Camera, CameraDetection)? ingest;
  final Map<String, _CameraMonitoringSession> _sessions = {};
  final Map<String, int> _generations = {};
  bool _disposed = false;

  bool get isRunning => _sessions.isNotEmpty;
  // Includes pending connections so a new configuration can cancel them.
  Set<String> get activeCameraIds => Set.unmodifiable(_sessions.keys);

  Future<void> start(Camera camera) async {
    if (_disposed) return;
    final generation = (_generations[camera.id] ?? 0) + 1;
    final existing = _sessions[camera.id];
    if (existing != null && _sameConfiguration(existing.camera, camera)) return;
    _generations[camera.id] = generation;
    _sessions.remove(camera.id);
    if (existing != null) await _close(existing);
    bool wanted() => !_disposed && _generations[camera.id] == generation;
    if (!wanted()) return;
    final provider = _providerFactory(camera);
    if (provider is! CameraDetectionSource) {
      await provider.dispose();
      return;
    }
    final session = _CameraMonitoringSession(camera, provider);
    _sessions[camera.id] = session;
    bool current() => wanted() && identical(_sessions[camera.id], session);
    try {
      session.subscription = (provider as CameraDetectionSource)
          .watchDetections()
          .listen(
            (detection) {
              if (current()) unawaited(_handleDetection(camera, detection));
            },
            onError: (Object _) {
              debugPrint(
                'CAMERA MONITORING: przerwane wykrywanie ${camera.id}',
              );
            },
          );
      await provider.connect().timeout(const Duration(seconds: 15));
      if (!current()) {
        await _close(session);
        return;
      }
      if (provider is CameraDetectionMonitoringController) {
        await (provider as CameraDetectionMonitoringController)
            .startDetectionMonitoring()
            .timeout(const Duration(seconds: 10));
      }
      if (!current()) await _close(session);
    } catch (error) {
      final wasCurrent = current();
      if (wasCurrent) _sessions.remove(camera.id);
      await _close(session);
      if (wasCurrent) rethrow;
    }
  }

  bool _sameConfiguration(Camera a, Camera b) =>
      a.connectionType == b.connectionType &&
      a.ipAddress == b.ipAddress &&
      a.onvifServiceUrl == b.onvifServiceUrl &&
      a.onvifDeviceId == b.onvifDeviceId &&
      setEquals(a.openPorts.toSet(), b.openPorts.toSet());

  Future<void> _handleDetection(
    Camera camera,
    CameraDetection detection,
  ) async {
    try {
      final sink = ingest;
      if (sink != null) {
        await sink(camera, detection);
      } else {
        await (cameraEventService ?? CameraEventService()).ingestFromCamera(
          cameraId: camera.id,
          type: detection.type,
          source: detection.source,
          confidence: detection.confidence,
          occurredAt: detection.occurredAt,
        );
      }
    } catch (_) {
      debugPrint('CAMERA MONITORING: nie zapisano zdarzenia ${camera.id}');
    }
  }

  Future<void> _close(_CameraMonitoringSession session) async {
    await session.subscription?.cancel();
    session.subscription = null;
    final provider = session.provider;
    if (provider is CameraDetectionMonitoringController) {
      try {
        await (provider as CameraDetectionMonitoringController)
            .stopDetectionMonitoring()
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await provider.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> stopCamera(String id) async {
    _generations[id] = (_generations[id] ?? 0) + 1;
    final session = _sessions.remove(id);
    if (session != null) await _close(session);
  }

  Future<void> stop() async {
    for (final id in {..._generations.keys, ..._sessions.keys}) {
      await stopCamera(id);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }
}

class _CameraMonitoringSession {
  _CameraMonitoringSession(this.camera, this.provider);
  final Camera camera;
  final CameraProvider provider;
  StreamSubscription<CameraDetection>? subscription;
}
