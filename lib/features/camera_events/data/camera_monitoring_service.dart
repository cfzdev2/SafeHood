import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../cameras/data/camera_provider_factory.dart';
import '../../cameras/domain/camera.dart';
import '../../cameras/domain/camera_provider.dart';
import 'camera_event_service.dart';

class CameraMonitoringService {
  final CameraEventService _cameraEventService;

  final Map<String, _CameraMonitoringSession> _sessions = {};

  final Set<String> _startingCameraIds = {};

  CameraMonitoringService({CameraEventService? cameraEventService})
    : _cameraEventService = cameraEventService ?? CameraEventService();

  bool get isRunning => _sessions.isNotEmpty;

  Set<String> get activeCameraIds => Set.unmodifiable(_sessions.keys);

  Future<void> start(Camera camera) async {
    final existingSession = _sessions[camera.id];

    if (existingSession != null) {
      if (_hasSameConnectionConfiguration(existingSession.camera, camera)) {
        debugPrint(
          'CAMERA MONITORING: '
          'kamera ${camera.id} już monitorowana',
        );

        return;
      }

      debugPrint(
        'CAMERA MONITORING: '
        'zmieniono konfigurację ${camera.id} '
        '— restart sesji',
      );

      await stopCamera(camera.id);
    }

    if (_startingCameraIds.contains(camera.id)) {
      debugPrint(
        'CAMERA MONITORING: '
        'kamera ${camera.id} już się uruchamia',
      );

      return;
    }

    _startingCameraIds.add(camera.id);

    CameraProvider? provider;

    StreamSubscription<CameraDetection>? detectionSubscription;

    try {
      debugPrint(
        'CAMERA MONITORING: '
        'start ${camera.id}',
      );

      provider = CameraProviderFactory.create(camera);

      if (provider is! CameraDetectionSource) {
        debugPrint(
          'CAMERA MONITORING: '
          'provider kamery ${camera.id} '
          'nie obsługuje wykryć',
        );

        await provider.dispose();

        return;
      }

      final detectionSource = provider as CameraDetectionSource;

      detectionSubscription = detectionSource.watchDetections().listen(
        (detection) {
          unawaited(_handleDetection(camera, detection));
        },
        onError: (Object error, StackTrace stackTrace) {
          debugPrint(
            'CAMERA MONITORING STREAM ERROR '
            '[${camera.id}]: '
            '$error',
          );

          debugPrint('$stackTrace');
        },
      );

      debugPrint(
        'CAMERA MONITORING: '
        'listener uruchomiony '
        '${camera.id}',
      );

      await provider.connect();

      if (provider is CameraDetectionMonitoringController) {
        await (provider as CameraDetectionMonitoringController)
            .startDetectionMonitoring();
      }

      _sessions[camera.id] = _CameraMonitoringSession(
        camera: camera,
        provider: provider,
        detectionSubscription: detectionSubscription,
      );

      debugPrint(
        'CAMERA MONITORING: '
        'aktywne ${camera.id}',
      );

      debugPrint(
        'CAMERA MONITORING: '
        'łącznie aktywnych = '
        '${_sessions.length}',
      );
    } catch (error, stackTrace) {
      debugPrint(
        'CAMERA MONITORING START ERROR '
        '[${camera.id}]: '
        '$error',
      );

      debugPrint('$stackTrace');

      if (detectionSubscription != null) {
        await detectionSubscription.cancel();
      }

      if (provider is CameraDetectionMonitoringController) {
        try {
          await (provider as CameraDetectionMonitoringController)
              .stopDetectionMonitoring();
        } catch (_) {}
      }

      if (provider != null) {
        try {
          await provider.dispose();
        } catch (_) {}
      }

      rethrow;
    } finally {
      _startingCameraIds.remove(camera.id);
    }
  }

  bool _hasSameConnectionConfiguration(Camera previous, Camera current) {
    return previous.connectionType == current.connectionType &&
        previous.ipAddress == current.ipAddress &&
        previous.onvifServiceUrl == current.onvifServiceUrl &&
        setEquals(previous.openPorts, current.openPorts);
  }

  Future<void> _handleDetection(
    Camera camera,
    CameraDetection detection,
  ) async {
    debugPrint(
      'CAMERA MONITORING DETECTION '
      '[${camera.id}]: '
      '${detection.type} → backend',
    );

    try {
      final result = await _cameraEventService.ingestFromCamera(
        cameraId: camera.id,
        type: detection.type,
        source: detection.source,
        confidence: detection.confidence,
        occurredAt: detection.occurredAt,
      );

      debugPrint(
        'CAMERA MONITORING INGEST '
        '[${camera.id}]: '
        'id=${result.eventId}, '
        'type=${result.type}, '
        'merged=${result.merged}, '
        'count=${result.occurrenceCount}',
      );
    } catch (error, stackTrace) {
      debugPrint(
        'CAMERA MONITORING INGEST ERROR '
        '[${camera.id}]: '
        '$error',
      );

      debugPrint('$stackTrace');
    }
  }

  Future<void> stopCamera(String cameraId) async {
    final session = _sessions.remove(cameraId);

    if (session == null) {
      return;
    }

    await session.detectionSubscription.cancel();

    final provider = session.provider;

    if (provider is CameraDetectionMonitoringController) {
      try {
        await (provider as CameraDetectionMonitoringController)
            .stopDetectionMonitoring();
      } catch (error) {
        debugPrint(
          'CAMERA MONITORING STOP EVENTS ERROR '
          '[$cameraId]: '
          '$error',
        );
      }
    }

    try {
      await provider.dispose();
    } catch (error) {
      debugPrint(
        'CAMERA MONITORING DISPOSE ERROR '
        '[$cameraId]: '
        '$error',
      );
    }

    debugPrint(
      'CAMERA MONITORING: '
      'zatrzymano $cameraId',
    );

    debugPrint(
      'CAMERA MONITORING: '
      'łącznie aktywnych = '
      '${_sessions.length}',
    );
  }

  Future<void> stop() async {
    final cameraIds = _sessions.keys.toList();

    for (final cameraId in cameraIds) {
      await stopCamera(cameraId);
    }
  }

  Future<void> dispose() async {
    await stop();
  }
}

class _CameraMonitoringSession {
  final Camera camera;
  final CameraProvider provider;

  final StreamSubscription<CameraDetection> detectionSubscription;

  const _CameraMonitoringSession({
    required this.camera,
    required this.provider,
    required this.detectionSubscription,
  });
}
