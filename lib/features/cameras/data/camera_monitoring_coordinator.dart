import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../bridges/domain/bridge_status.dart';
import '../domain/camera.dart';
import 'camera_background_motion.dart';
import 'camera_service.dart';

enum AutomaticMonitoringStatus {
  off,
  connecting,
  independent,
  phone,
  unavailable;

  String get message => switch (this) {
    off => 'Wykrywanie ruchu jest wyłączone.',
    connecting => 'SafeHood łączy monitoring z kamerą.',
    independent => 'Monitoring działa bez otwartego SafeHood na telefonie.',
    phone =>
      'Ruch wykrywa telefon. Kamera nie ma jeszcze potwierdzonego monitoringu niezależnego od telefonu.',
    unavailable =>
      'Brak działającego połączenia do monitoringu. Sam podgląd nie potwierdza odbierania zdarzeń.',
  };
}

bool cameraMotionIsEnabled(Camera camera) =>
    camera.liveMotionEnabled ||
    (camera.connectionType == CameraConnectionType.onvif &&
        camera.motionDetectionEnabled);

bool hasIndependentCameraMonitoring(
  Camera camera,
  Iterable<BridgeStatus> bridges,
  DateTime now,
) {
  if (camera.monitoringMode != CameraMonitoringMode.bridge ||
      camera.bridgeId == null ||
      camera.bridgeMonitoringStatus != CameraMonitoringRuntimeStatus.online) {
    return false;
  }
  final checkedAt = camera.bridgeMonitoringUpdatedAt;
  if (checkedAt == null) return false;
  final age = now.difference(checkedAt);
  if (age < const Duration(seconds: -5) || age > const Duration(seconds: 90)) {
    return false;
  }
  return bridges.any(
    (bridge) => bridge.id == camera.bridgeId && bridge.isOnlineAt(now),
  );
}

/// One saved motion preference drives both independent and phone receivers.
/// A successful camera preview never counts as an independent monitor.
class CameraMonitoringCoordinator extends ChangeNotifier {
  CameraMonitoringCoordinator({
    required this.phoneStatus,
    required this.refreshPhone,
    required this.startPhone,
    required this.stopPhone,
    required this.assignBridge,
    required this.supportsPhone,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final instance = CameraMonitoringCoordinator(
    phoneStatus: CameraBackgroundMotion.instance.status,
    refreshPhone: CameraBackgroundMotion.instance.refresh,
    startPhone: (camera) async {
      await CameraBackgroundMotion.instance.start(camera);
    },
    stopPhone: CameraBackgroundMotion.instance.stop,
    assignBridge: (id) async {
      await CameraService().assignToOnlineBridge(id);
    },
    supportsPhone: CameraBackgroundMotion.supported,
  );

  final ValueListenable<CameraBackgroundMotionStatus> phoneStatus;
  final Future<void> Function() refreshPhone;
  final Future<void> Function(Camera) startPhone;
  final Future<void> Function(String) stopPhone;
  final Future<void> Function(String) assignBridge;
  final bool Function(Camera) supportsPhone;
  final DateTime Function() _now;
  final _bridgeAttempts = <String, DateTime>{};
  final _phoneAttempts = <String, DateTime>{};
  final _suppressed = <String>{};
  final _plannedStops = <String>{};
  List<Camera> _cameras = const [];
  List<BridgeStatus> _bridges = const [];
  Future<void>? _pending;
  Timer? _timer;
  String? _previousPhone;
  bool _foreground = true;
  bool _dirty = false;
  bool _running = false;
  bool _disposed = false;
  int _generation = 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  int begin() {
    if (!_running) phoneStatus.addListener(_phoneChanged);
    _running = true;
    _cameras = const [];
    _bridges = const [];
    _bridgeAttempts.clear();
    _phoneAttempts.clear();
    _suppressed.clear();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_foreground) unawaited(synchronize());
      _notify();
    });
    return ++_generation;
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground && _running) unawaited(synchronize());
  }

  Future<void> updateCameras(List<Camera> cameras) {
    for (final previous in _cameras) {
      if (cameras.any(
        (current) =>
            current.id == previous.id &&
            current.liveMotionEnabled != previous.liveMotionEnabled,
      )) {
        _phoneAttempts.remove(previous.id);
        _suppressed.remove(previous.id);
      }
    }
    _cameras = List.of(cameras);
    _notify();
    return synchronize();
  }

  Future<void> updateBridges(List<BridgeStatus> bridges) {
    _bridges = List.of(bridges);
    _notify();
    return synchronize();
  }

  Future<void> intentChanged(Camera camera) {
    _phoneAttempts.remove(camera.id);
    _suppressed.remove(camera.id);
    return updateCameras([
      for (final existing in _cameras)
        if (existing.id != camera.id) existing,
      camera,
    ]);
  }

  AutomaticMonitoringStatus statusFor(Camera camera) {
    camera =
        _cameras.where((item) => item.id == camera.id).firstOrNull ?? camera;
    if (!cameraMotionIsEnabled(camera)) return AutomaticMonitoringStatus.off;
    if (hasIndependentCameraMonitoring(camera, _bridges, _now())) {
      return AutomaticMonitoringStatus.independent;
    }
    final phone = phoneStatus.value;
    if (phone.cameraId == camera.id) {
      if (phone.phase == 'watching' || phone.phase == 'preview') {
        return AutomaticMonitoringStatus.phone;
      }
      if (phone.phase == 'starting' || phone.phase == 'reconnecting') {
        return AutomaticMonitoringStatus.connecting;
      }
    }
    return AutomaticMonitoringStatus.unavailable;
  }

  void _phoneChanged() {
    final current = phoneStatus.value.cameraId;
    // Respect the user's Stop action from Android's notification.
    if (_previousPhone != null && current == null) {
      if (!_plannedStops.remove(_previousPhone)) {
        _suppressed.add(_previousPhone!);
      }
    }
    _previousPhone = current;
    _notify();
  }

  Future<void> synchronize() {
    if (!_running) return Future.value();
    _dirty = true;
    return _pending ??= _drain().whenComplete(() => _pending = null);
  }

  Future<void> _drain() async {
    while (_dirty && _running) {
      _dirty = false;
      final generation = _generation;
      await _sync(generation);
    }
  }

  Future<void> _stop(String cameraId) async {
    _plannedStops.add(cameraId);
    await stopPhone(cameraId);
    await refreshPhone();
  }

  Future<void> _sync(int generation) async {
    bool current() => _running && generation == _generation;
    final desired = _cameras
        .where(
          (camera) =>
              camera.usesLocalConnection && cameraMotionIsEnabled(camera),
        )
        .toList();
    final now = _now();

    // Assign only when a real receiver is online; assignment isn't a proof
    // of camera connectivity. Keep the phone until camera heartbeats confirm it.
    if (_foreground && _bridges.any((bridge) => bridge.isOnlineAt(now))) {
      for (final camera in desired) {
        if (!current()) return;
        if (camera.connectionType != CameraConnectionType.onvif ||
            !camera.liveMotionEnabled ||
            (camera.bridgeId != null &&
                camera.monitoringMode == CameraMonitoringMode.bridge &&
                _bridges.any(
                  (bridge) =>
                      bridge.id == camera.bridgeId && bridge.isOnlineAt(now),
                ))) {
          continue;
        }
        final last = _bridgeAttempts[camera.id];
        if (last != null && now.difference(last) < const Duration(minutes: 1)) {
          continue;
        }
        _bridgeAttempts[camera.id] = now;
        try {
          await assignBridge(camera.id);
        } catch (_) {
          // A missing independent receiver must not disable phone detection.
        }
      }
    }
    if (!current()) return;
    try {
      await refreshPhone();
      if (!current()) return;
      var activeId = phoneStatus.value.cameraId;
      final candidates = desired
          .where(
            (camera) =>
                camera.liveMotionEnabled &&
                supportsPhone(camera) &&
                !hasIndependentCameraMonitoring(camera, _bridges, _now()),
          )
          .toList();
      if (activeId != null &&
          !candidates.any((camera) => camera.id == activeId)) {
        await _stop(activeId);
        activeId = phoneStatus.value.cameraId;
      }
      if (!current() || !_foreground || activeId != null) return;
      // The current Android receiver handles one camera. Don't silently select
      // a random camera and present the whole home as protected.
      if (candidates.length != 1) return;
      final camera = candidates.single;
      if (_suppressed.contains(camera.id)) return;
      final last = _phoneAttempts[camera.id];
      if (last != null && now.difference(last) < const Duration(minutes: 1)) {
        return;
      }
      _phoneAttempts[camera.id] = now;
      await startPhone(camera);
      if (!current()) {
        await _stop(camera.id);
      } else {
        await refreshPhone();
      }
    } catch (_) {
      // The UI reports actual runtime state, never success from a saved switch.
    } finally {
      _notify();
    }
  }

  void end(int generation) {
    if (generation != _generation) return;
    _running = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    phoneStatus.removeListener(_phoneChanged);
    _cameras = const [];
    _bridges = const [];
    final cameraId = phoneStatus.value.cameraId;
    if (cameraId != null) unawaited(_stop(cameraId));
  }

  @override
  void dispose() {
    end(_generation);
    _disposed = true;
    super.dispose();
  }
}
