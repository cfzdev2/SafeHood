import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/bridges/domain/bridge_status.dart';
import 'package:safehood/features/cameras/data/camera_background_motion.dart';
import 'package:safehood/features/cameras/data/camera_monitoring_coordinator.dart';
import 'package:safehood/features/cameras/domain/camera.dart';

const enabled = Camera(
  id: 'robot',
  name: 'Robot',
  locationName: 'Pokój',
  brand: 'Test',
  model: 'Test',
  isOnline: true,
  motionDetectionEnabled: true,
  liveMotionEnabled: true,
  hasSdCard: false,
  connectionType: CameraConnectionType.onvif,
);

void main() {
  test(
    'only a backend-confirmed vendor callback can replace the phone receiver',
    () async {
      final h = Harness();
      addTearDown(h.controller.dispose);
      await h.controller.updateCameras([enabled]);
      await h.controller.updateCameras([
        enabled.copyWith(xmMonitoringStatus: 'subscribed'),
      ]);
      expect(h.stopped, isEmpty);
      final confirmed = enabled.copyWith(
        xmMonitoringStatus: 'confirmed',
        xmMonitoringConfirmedAt: h.now,
        monitoringMode: CameraMonitoringMode.cloud,
      );
      await h.controller.updateCameras([confirmed]);
      expect(h.stopped, ['robot']);
      expect(
        h.controller.statusFor(confirmed),
        AutomaticMonitoringStatus.independent,
      );
      await h.controller.updateCameras([
        confirmed.copyWith(xmMonitoringStatus: 'revoked'),
      ]);
      expect(h.started, ['robot', 'robot']);
    },
  );
  test('one motion setting starts monitoring without opening live', () async {
    final h = Harness();
    addTearDown(h.controller.dispose);
    await h.controller.updateCameras([enabled]);
    expect(h.started, ['robot']);
    expect(h.controller.statusFor(enabled), AutomaticMonitoringStatus.phone);

    h.controller.setForeground(false);
    await h.controller.synchronize();
    expect(h.stopped, isEmpty);
    await h.controller.updateCameras([
      enabled.copyWith(liveMotionEnabled: false, motionDetectionEnabled: false),
    ]);
    expect(h.stopped, ['robot']);
    expect(h.state.value.cameraId, isNull);
  });

  test(
    'saved preference resumes automatically without duplicate receivers',
    () async {
      final h = Harness();
      addTearDown(h.controller.dispose);
      await h.controller.updateCameras([enabled]);
      await h.controller.updateCameras([enabled.copyWith(name: 'Nowa nazwa')]);
      await h.controller.updateBridges(const []);
      expect(h.started, ['robot']);
    },
  );

  test(
    'Bridge assignment alone cannot claim monitoring or stop the phone',
    () async {
      final h = Harness();
      addTearDown(h.controller.dispose);
      await h.controller.updateBridges([h.bridge]);
      await h.controller.updateCameras([enabled]);
      expect(h.assigned, ['robot']);
      final assigned = enabled.copyWith(
        bridgeId: 'bridge',
        bridgeMonitoringStatus: CameraMonitoringRuntimeStatus.connecting,
      );
      await h.controller.updateCameras([assigned]);
      expect(h.stopped, isEmpty);
      expect(h.controller.statusFor(assigned), AutomaticMonitoringStatus.phone);
    },
  );

  test(
    'confirmed Bridge takes over; stale heartbeats restore the phone',
    () async {
      final h = Harness();
      addTearDown(h.controller.dispose);
      await h.controller.updateCameras([enabled]);
      await h.controller.updateBridges([h.bridge]);
      final healthy = enabled.copyWith(
        bridgeId: 'bridge',
        bridgeMonitoringStatus: CameraMonitoringRuntimeStatus.online,
        bridgeMonitoringUpdatedAt: h.now,
      );
      await h.controller.updateCameras([healthy]);
      expect(h.stopped, ['robot']);
      expect(
        h.controller.statusFor(healthy),
        AutomaticMonitoringStatus.independent,
      );

      h.now = h.now.add(const Duration(minutes: 2));
      await h.controller.synchronize();
      expect(h.started, ['robot', 'robot']);
      expect(h.controller.statusFor(healthy), AutomaticMonitoringStatus.phone);
    },
  );

  test('an online Bridge cannot validate an old camera status', () {
    final h = Harness();
    addTearDown(h.controller.dispose);
    final stale = enabled.copyWith(
      bridgeId: 'bridge',
      bridgeMonitoringStatus: CameraMonitoringRuntimeStatus.online,
      bridgeMonitoringUpdatedAt: h.now.subtract(const Duration(minutes: 2)),
    );
    expect(hasIndependentCameraMonitoring(stale, [h.bridge], h.now), isFalse);
    expect(
      hasIndependentCameraMonitoring(
        stale.copyWith(bridgeMonitoringUpdatedAt: h.now),
        [h.bridge],
        h.now,
      ),
      isTrue,
    );
    expect(
      h.controller.statusFor(enabled),
      AutomaticMonitoringStatus.unavailable,
    );
  });

  test(
    'Stop from Android is respected until motion is enabled again',
    () async {
      final h = Harness();
      addTearDown(h.controller.dispose);
      await h.controller.updateCameras([enabled]);
      h.state.value = const CameraBackgroundMotionStatus();
      h.now = h.now.add(const Duration(minutes: 2));
      await h.controller.synchronize();
      expect(h.started, ['robot']);
      await h.controller.intentChanged(enabled);
      expect(h.started, ['robot', 'robot']);
    },
  );

  test(
    'motion disabled during startup cannot leave an orphan receiver',
    () async {
      final h = Harness();
      addTearDown(h.controller.dispose);
      final opening = Completer<void>();
      h.opening = opening.future;
      final start = h.controller.updateCameras([enabled]);
      await Future<void>.delayed(Duration.zero);
      final stop = h.controller.updateCameras([
        enabled.copyWith(
          liveMotionEnabled: false,
          motionDetectionEnabled: false,
        ),
      ]);
      opening.complete();
      await Future.wait([start, stop]);
      expect(h.stopped, ['robot']);
      expect(h.state.value.cameraId, isNull);
    },
  );

  test(
    'every unmonitored camera shows the missing independent connection',
    () async {
      final h = Harness();
      addTearDown(h.controller.dispose);
      final other = enabled.copyWith(id: 'other');
      await h.controller.updateCameras([enabled, other]);
      expect(h.started, isEmpty);
      expect(
        h.controller.statusFor(enabled),
        AutomaticMonitoringStatus.unavailable,
      );
      expect(
        h.controller.statusFor(other),
        AutomaticMonitoringStatus.unavailable,
      );
    },
  );
}

class Harness {
  final state = ValueNotifier(const CameraBackgroundMotionStatus());
  final started = <String>[];
  final stopped = <String>[];
  final assigned = <String>[];
  DateTime now = DateTime.utc(2026, 11, 23);
  Future<void>? opening;
  late final CameraMonitoringCoordinator controller;

  Harness() {
    controller = CameraMonitoringCoordinator(
      phoneStatus: state,
      refreshPhone: () async {},
      startPhone: (camera) async {
        started.add(camera.id);
        await opening;
        state.value = CameraBackgroundMotionStatus(
          cameraId: camera.id,
          phase: 'watching',
        );
      },
      stopPhone: (id) async {
        stopped.add(id);
        state.value = const CameraBackgroundMotionStatus();
      },
      assignBridge: (id) async {
        assigned.add(id);
      },
      supportsPhone: (_) => true,
      now: () => now,
    )..begin();
  }

  BridgeStatus get bridge => BridgeStatus(
    id: 'bridge',
    name: 'Bridge',
    status: 'online',
    platform: '',
    version: '',
    activeCameraCount: 1,
    lastSeenAt: now,
  );
}
