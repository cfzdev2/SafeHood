import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/local_camera_connection.dart';
import 'package:safehood/features/cameras/data/native_camera_profile.dart';
import 'package:safehood/features/cameras/data/xm_camera_service.dart';
import 'package:safehood/features/cameras/domain/camera.dart';

const camera = Camera(
  id: 'camera',
  name: 'Camera',
  locationName: '',
  brand: '',
  model: '',
  isOnline: true,
  motionDetectionEnabled: true,
  hasSdCard: false,
  connectionType: CameraConnectionType.onvif,
);
const profile = NativeCameraProfile(
  protocol: 'dvrip',
  serialNumber: '0123456789abcdef',
  motionSupported: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('safehood/test_xm');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'a build without approved SDK keys never provisions an external account',
    () async {
      final requests = <String>[];
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'available': false},
      );
      final service = XmCameraService(
        channel: channel,
        currentOwner: () => 'owner',
        supported: () => true,
        backend: (method, data) async {
          requests.add(method);
          return {};
        },
      );
      expect(
        await service.ensureCamera(
          camera: camera,
          profile: profile,
          login: const CameraLogin('admin', ''),
        ),
        false,
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'automatically connects one account and retries reuse the same job',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add('sdk:${call.method}');
        if (call.method == 'available') return {'available': true};
        expect((call.arguments as Map)['owner'], 'owner');
        return {'ok': true};
      });
      final service = XmCameraService(
        channel: channel,
        currentOwner: () => 'owner',
        supported: () => true,
        backend: (method, data) async {
          calls.add(method);
          return switch (method) {
            'provisionXmCameraAccount' => {
              'username': 'test',
              'password': 'private',
              'needsRegistration': true,
            },
            'createXmAlarmRoute' => {
              'routeId': 'a' * 32,
              'callbackUrl':
                  'https://callbacks.example.test/receive/${'a' * 32}/${'b' * 64}',
            },
            _ => {'ok': true},
          };
        },
      );
      Future<bool> connect() => service.ensureCamera(
        camera: camera,
        profile: profile,
        login: const CameraLogin('admin', 'private-device-password'),
      );
      expect(await Future.wait([connect(), connect()]), [true, true]);
      expect(calls, [
        'sdk:available',
        'provisionXmCameraAccount',
        'sdk:ensureAccount',
        'confirmXmCameraAccount',
        'createXmAlarmRoute',
        'bindXmCamera',
        'sdk:subscribe',
        'confirmXmAlarmSubscription',
      ]);
    },
  );

  test(
    'sign-out during account provisioning cannot pass old credentials to another owner',
    () async {
      var owner = 'first';
      final provisioning = Completer<Map<String, dynamic>>();
      final nativeCalls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call.method);
        return {'available': true};
      });
      final service = XmCameraService(
        channel: channel,
        currentOwner: () => owner,
        supported: () => true,
        backend: (method, data) => provisioning.future,
      );
      final result = service.ensureCamera(
        camera: camera,
        profile: profile,
        login: const CameraLogin('admin', ''),
      );
      await Future<void>.delayed(Duration.zero);
      owner = 'second';
      provisioning.complete({
        'username': 'first-account',
        'password': 'first-password',
      });
      expect(await result, false);
      expect(nativeCalls, ['available']);
    },
  );

  test(
    'rejects a non-HTTPS callback before sending camera credentials to the SDK',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'available' ? {'available': true} : {'ok': true};
      });
      final service = XmCameraService(
        channel: channel,
        currentOwner: () => 'owner',
        supported: () => true,
        backend: (method, data) async => method == 'createXmAlarmRoute'
            ? {
                'routeId': 'a' * 32,
                'callbackUrl': 'http://example.test/callback',
              }
            : {'username': 'test', 'password': 'test', 'ok': true},
      );
      expect(
        await service.ensureCamera(
          camera: camera,
          profile: profile,
          login: const CameraLogin('admin', ''),
        ),
        false,
      );
      expect(calls, ['available', 'ensureAccount']);
    },
  );

  test(
    'native profile parsing never accepts another protocol or malformed identity',
    () {
      expect(NativeCameraProfile.fromMap({'protocol': 'unknown'}), isNull);
      final parsed = NativeCameraProfile.fromMap({
        'protocol': 'dvrip',
        'serialNumber': '../../owner',
        'motionSupported': 'true',
      });
      expect(parsed?.serialNumber, isNull);
      expect(parsed?.motionSupported, false);
      expect(
        NativeCameraProfile.fromMap(profile.toMap())?.serialNumber,
        profile.serialNumber,
      );
    },
  );
}
