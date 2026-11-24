import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/camera_events/data/camera_monitoring_service.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/domain/camera_provider.dart';

const camera = Camera(
  id: 'robot',
  name: 'Robot',
  locationName: 'Pokój',
  brand: '',
  model: '',
  isOnline: true,
  motionDetectionEnabled: true,
  hasSdCard: false,
  ipAddress: '192.168.1.9',
  connectionType: CameraConnectionType.onvif,
);

class PendingProvider extends CameraProvider
    implements CameraDetectionSource, CameraDetectionMonitoringController {
  PendingProvider(this.camera);
  @override
  final Camera camera;
  final connected = Completer<void>();
  final detections = StreamController<CameraDetection>.broadcast(sync: true);
  int started = 0;
  int disposed = 0;

  @override
  Future<void> connect() => connected.future;
  @override
  Stream<CameraDetection> watchDetections() => detections.stream;
  @override
  Future<void> startDetectionMonitoring() async {
    started++;
  }

  @override
  Future<void> stopDetectionMonitoring() async {}
  @override
  Future<void> dispose() async {
    disposed++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'disabling monitoring during connection cannot revive its receiver',
    () async {
      final provider = PendingProvider(camera);
      var events = 0;
      final service = CameraMonitoringService(
        providerFactory: (_) => provider,
        ingest: (_, _) async {
          events++;
        },
      );
      addTearDown(service.dispose);
      addTearDown(provider.detections.close);
      final starting = service.start(camera);
      expect(service.activeCameraIds, contains('robot'));
      await service.stopCamera(camera.id);
      provider.connected.complete();
      await starting;
      provider.detections.add(
        CameraDetection(
          type: 'motion',
          source: 'onvif',
          occurredAt: DateTime.now(),
        ),
      );
      expect(provider.started, 0);
      expect(service.isRunning, false);
      expect(events, 0);
    },
  );

  test(
    'an old connection cannot replace the receiver for a new address',
    () async {
      final providers = <PendingProvider>[];
      final service = CameraMonitoringService(
        providerFactory: (value) {
          final provider = PendingProvider(value);
          providers.add(provider);
          return provider;
        },
        ingest: (_, _) async {},
      );
      addTearDown(service.dispose);
      final first = service.start(camera);
      final second = service.start(camera.copyWith(ipAddress: '192.168.1.11'));
      await Future<void>.delayed(Duration.zero);
      expect(providers, hasLength(2));
      providers.last.connected.complete();
      await second;
      providers.first.connected.complete();
      await first;
      expect(providers.first.started, 0);
      expect(providers.last.started, 1);
      expect(service.activeCameraIds, {'robot'});
      await service.stop();
      for (final provider in providers) {
        await provider.detections.close();
      }
    },
  );
}
