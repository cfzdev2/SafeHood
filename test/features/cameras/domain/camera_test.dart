import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/domain/camera.dart';

void main() {
  group('Camera', () {
    test('fromMap używa bezpiecznych wartości domyślnych', () {
      final camera = Camera.fromMap('camera-1', {});

      expect(camera.id, 'camera-1');
      expect(camera.name, '');
      expect(camera.locationName, '');
      expect(camera.brand, 'Nieznana');
      expect(camera.model, 'Nieznany');
      expect(camera.isOnline, isFalse);
      expect(camera.availabilityCheckedAt, isNull);
      expect(camera.motionDetectionEnabled, isTrue);
      expect(camera.hasSdCard, isFalse);
      expect(camera.connectionType, CameraConnectionType.mock);
      expect(camera.cloudProvider, isNull);
      expect(camera.monitoringMode, CameraMonitoringMode.bridge);
      expect(
        camera.bridgeMonitoringStatus,
        CameraMonitoringRuntimeStatus.unknown,
      );
      expect(camera.openPorts, isEmpty);
      expect(camera.discoverySources, isEmpty);
    });

    test('fromMap odczytuje pełne dane kamery', () {
      final checkedAt = DateTime.utc(2026, 9, 18, 16, 30);

      final camera = Camera.fromMap('camera-2', {
        'name': 'DEKCO Podjazd',
        'locationName': 'Podjazd',
        'brand': 'DEKCO',
        'model': 'L5P',
        'ipAddress': ' 192.168.1.10 ',
        'macAddress': ' AA:BB:CC:DD:EE:FF ',
        'onvifServiceUrl': ' http://192.168.1.10/onvif ',
        'openPorts': [8899, 554.0, 8899, '80'],
        'discoverySources': ['onvif', 'ssdp', '', '   ', 123],
        'isOnline': true,
        'availabilityCheckedAt': Timestamp.fromDate(checkedAt),
        'motionDetectionEnabled': false,
        'hasSdCard': true,
        'connectionType': 'manufacturerCloud',
        'cloudProvider': 'safeArk',
        'cloudDeviceId': ' debug-dekco-l5p-1 ',
        'monitoringMode': 'cloud',
        'bridgeId': ' bridge-1 ',
        'bridgeMonitoringStatus': 'online',
      });

      expect(camera.name, 'DEKCO Podjazd');
      expect(camera.locationName, 'Podjazd');
      expect(camera.brand, 'DEKCO');
      expect(camera.model, 'L5P');
      expect(camera.ipAddress, '192.168.1.10');
      expect(camera.macAddress, 'AA:BB:CC:DD:EE:FF');
      expect(camera.onvifServiceUrl, 'http://192.168.1.10/onvif');
      expect(camera.openPorts, unorderedEquals([554, 8899]));
      expect(camera.discoverySources, unorderedEquals(['onvif', 'ssdp']));
      expect(camera.isOnline, isTrue);
      expect(camera.availabilityCheckedAt?.toUtc(), checkedAt);
      expect(camera.motionDetectionEnabled, isFalse);
      expect(camera.hasSdCard, isTrue);
      expect(camera.connectionType, CameraConnectionType.manufacturerCloud);
      expect(camera.cloudProvider, CameraCloudProvider.safeArk);
      expect(camera.cloudDeviceId, 'debug-dekco-l5p-1');
      expect(camera.monitoringMode, CameraMonitoringMode.cloud);
      expect(camera.bridgeId, 'bridge-1');
      expect(
        camera.bridgeMonitoringStatus,
        CameraMonitoringRuntimeStatus.online,
      );
    });

    test('fromMap bezpiecznie obsługuje nieznane wartości enum', () {
      final camera = Camera.fromMap('camera-3', {
        'connectionType': 'futureConnection',
        'cloudProvider': 'futureProvider',
        'monitoringMode': 'futureMode',
        'bridgeMonitoringStatus': 'futureStatus',
      });

      expect(camera.connectionType, CameraConnectionType.unknown);
      expect(camera.cloudProvider, CameraCloudProvider.unknown);
      expect(camera.monitoringMode, CameraMonitoringMode.bridge);
      expect(
        camera.bridgeMonitoringStatus,
        CameraMonitoringRuntimeStatus.unknown,
      );
    });

    test('toMap zapisuje dane w prawidłowym formacie', () {
      final checkedAt = DateTime.utc(2026, 9, 18, 17);

      final camera = Camera(
        id: 'camera-4',
        name: 'Garaż',
        locationName: 'Garaż',
        brand: 'Test',
        model: 'Test 1',
        ipAddress: '192.168.1.20',
        openPorts: const {8899, 80, 554},
        discoverySources: const {'ssdp', 'onvif', 'mdns'},
        isOnline: true,
        availabilityCheckedAt: checkedAt,
        motionDetectionEnabled: true,
        hasSdCard: false,
        connectionType: CameraConnectionType.onvif,
        monitoringMode: CameraMonitoringMode.bridge,
        bridgeId: 'bridge-1',
        bridgeMonitoringStatus: CameraMonitoringRuntimeStatus.online,
      );

      final map = camera.toMap();

      expect(map['name'], 'Garaż');
      expect(map['connectionType'], 'onvif');
      expect(map['monitoringMode'], 'bridge');
      expect(map['availabilityCheckedAt'], checkedAt);
      expect(map['openPorts'], [80, 554, 8899]);
      expect(map['discoverySources'], ['mdns', 'onvif', 'ssdp']);
      expect(map.containsKey('id'), isFalse);
      expect(map.containsKey('bridgeMonitoringStatus'), isFalse);
    });

    test('copyWith zmienia tylko wskazane dane', () {
      const original = Camera(
        id: 'camera-5',
        name: 'Stara nazwa',
        locationName: 'Podjazd',
        brand: 'DEKCO',
        model: 'L5P',
        isOnline: false,
        motionDetectionEnabled: true,
        hasSdCard: false,
      );

      final updated = original.copyWith(
        name: 'Nowa nazwa',
        isOnline: true,
        bridgeMonitoringStatus: CameraMonitoringRuntimeStatus.online,
      );

      expect(updated.id, original.id);
      expect(updated.name, 'Nowa nazwa');
      expect(updated.locationName, original.locationName);
      expect(updated.brand, original.brand);
      expect(updated.model, original.model);
      expect(updated.isOnline, isTrue);
      expect(updated.motionDetectionEnabled, isTrue);
      expect(
        updated.bridgeMonitoringStatus,
        CameraMonitoringRuntimeStatus.online,
      );
    });
  });
}
