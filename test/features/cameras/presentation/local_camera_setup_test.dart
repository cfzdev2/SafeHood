import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/camera_discovery_service.dart';
import 'package:safehood/features/cameras/data/local_camera_registration.dart';
import 'package:safehood/features/cameras/data/local_camera_store.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/presentation/local_camera_preview.dart';
import 'package:safehood/features/cameras/presentation/local_camera_setup_screen.dart';

const _player = MethodChannel('safehood/local_camera_player');
const _reolink = MethodChannel('safehood/reolink_pairing');
const _pairing = MethodChannel('safehood/camera_hotspot_pairing');

const _nvt = DetectedCamera(
  deviceId: 'nvt',
  displayName: 'Kamera ONVIF 192.168.1.9',
  brand: 'Nieznany producent',
  model: 'NVT',
  ipAddress: '192.168.1.9',
  onvifServiceUrl: 'http://192.168.1.9:8899/onvif/device_service',
  connectionType: CameraConnectionType.onvif,
  openPorts: {8899, 554},
);

class _Discovery extends CameraDiscoveryService {
  _Discovery({this.results = const [[]], this.saved});

  final List<List<DetectedCamera>> results;
  final DetectedCamera? saved;
  final searchedAddresses = <String>[];
  int scans = 0;

  @override
  Future<List<DetectedCamera>> discoverCameras({
    void Function(CameraDiscoveryProgress progress)? onProgress,
    void Function(List<DetectedCamera> cameras)? onResults,
    bool Function()? isCancelled,
  }) async {
    final index = scans++;
    return results[index < results.length ? index : results.length - 1];
  }

  @override
  Future<DetectedCamera?> findLocalCamera(String address) async {
    searchedAddresses.add(address);
    return saved;
  }
}

class _ControlledProbe implements CameraDiscoveryStrategy {
  _ControlledProbe(this.name);

  @override
  final String name;
  int scans = 0;
  late Completer<List<DetectedCamera>> result;
  void Function(List<DetectedCamera>)? publish;

  @override
  Future<List<DetectedCamera>> discover({
    void Function(List<DetectedCamera>)? onResults,
    bool Function()? isCancelled,
  }) {
    scans++;
    publish = onResults;
    result = Completer();
    return result.future;
  }
}

Future<void> _largeScreen(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RTSP input only accepts local literal camera addresses', () {
    expect(
      parseLocalRtsp('rtsp://user:p%40ss@192.168.0.7:554/stream'),
      isNotNull,
    );
    expect(parseLocalRtsp('rtsp://10.4.2.1/cam?profile=2'), isNotNull);
    for (final invalid in [
      'http://192.168.1.2/live',
      'rtsp://example.test/live',
      'rtsp://127.0.0.1:18554/blinkhd',
      'rtsp://169.254.1.2/live',
      'rtsp://192.168.1.2:70000/live',
      'rtsp://192.168.1.2/live#fragment',
      'rtsp://192.168.1.2/live%ZZ',
      'rtsp://192.168.1.2/live\u0000',
    ]) {
      expect(parseLocalRtsp(invalid), isNull, reason: invalid);
    }
  });

  testWidgets('retry shows a camera before the deeper search finishes', (
    tester,
  ) async {
    final direct = _ControlledProbe('DIRECT');
    final standard = _ControlledProbe('STANDARD');
    final lan = _ControlledProbe('LAN');
    await tester.pumpWidget(
      MaterialApp(
        home: LocalCameraSetupScreen(
          discovery: CameraDiscoveryService.withStrategies(
            networkStrategies: [direct, standard],
            lanStrategy: lan,
          ),
          onSave: (_) async => fail('Search alone must not save a camera'),
        ),
      ),
    );
    expect([direct.scans, standard.scans], [1, 1]);
    direct.result.complete([]);
    standard.result.complete([]);
    await tester.pump();
    lan.result.complete([]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Nie znaleziono kamer'), findsOneWidget);

    await tester.tap(find.text('Szukaj ponownie'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect([direct.scans, standard.scans, lan.scans], [2, 2, 1]);
    expect(find.text('Szukam kamer w Twojej sieci…'), findsOneWidget);

    final camera = _nvt.copyWith(confidence: 100);
    direct.publish!([camera]);
    await tester.pump();
    expect(find.text('Szukam kolejnych kamer…'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, '192.168.1.9'))
          .onTap,
      isNotNull,
    );

    direct.result.complete([camera]);
    standard.result.complete([camera.copyWith(deviceId: 'duplicate')]);
    await tester.pump();
    expect(lan.scans, 2);
    expect(find.text('192.168.1.9'), findsOneWidget);

    lan.result.complete([
      camera.copyWith(
        deviceId: 'silent-camera',
        ipAddress: '192.168.1.10',
        onvifServiceUrl: 'http://192.168.1.10/onvif/device_service',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('192.168.1.9'), findsOneWidget);
    expect(find.text('192.168.1.10'), findsOneWidget);
    expect(find.text('Szukaj ponownie'), findsOneWidget);
  });

  testWidgets('imports the saved stream only after a frame and allows retry', (
    tester,
  ) async {
    await _largeScreen(tester);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var firstFrame = false;
    var attempts = 0;
    LocalCameraRegistration? added;
    LocalCameraSetupResult? result;
    messenger.setMockMethodCallHandler(_player, (call) async {
      calls.add(call);
      return switch (call.method) {
        'resolveOnvif' => throw PlatformException(code: 'noOnvifStream'),
        'open' => 12,
        'state' => {
          'rendered': firstFrame,
          'width': 1280,
          'height': 720,
          'failed': false,
        },
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_player, null));
    final source = LocalCameraSource(
      name: 'Kamera',
      uri: Uri.parse('rtsp://user:example@192.168.1.40/live?sub=1'),
    );
    final discovery = _Discovery(
      saved: _nvt.copyWith(
        ipAddress: '192.168.1.40',
        onvifServiceUrl: 'http://192.168.1.40:8899/onvif/device_service',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<LocalCameraSetupResult>(
                MaterialPageRoute<LocalCameraSetupResult>(
                  builder: (_) => LocalCameraSetupScreen(
                    savedSource: source,
                    discovery: discovery,
                    onSave: (camera) async {
                      if (++attempts == 1) {
                        throw StateError('Firestore offline');
                      }
                      added = camera;
                    },
                  ),
                ),
              );
            },
            child: const Text('Open preview'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preview'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(discovery.searchedAddresses, ['192.168.1.40']);
    expect(calls.map((call) => call.method).take(2), ['resolveOnvif', 'open']);
    expect(find.text('Przenieś sam podgląd RTSP'), findsNothing);
    final save = find.ancestor(
      of: find.text('Dodaj kamerę'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    firstFrame = true;
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(added, isNull);
    expect(result, isNull);
    expect(find.byType(LocalCameraPreview), findsOneWidget);
    expect(find.textContaining('Nie udało się dodać kamery'), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(result, LocalCameraSetupResult.saved);
    expect(added?.connection.rtspUri, source.uri);
    expect(added?.camera.ipAddress, source.uri.host);
    expect(added?.camera.connectionType, CameraConnectionType.rtsp);
    expect(
      calls.any((call) => call.method == 'stop' && call.arguments['id'] == 12),
      isTrue,
    );
  });

  testWidgets('tries playback candidates and saves the one with video', (
    tester,
  ) async {
    await _largeScreen(tester);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final opened = <Uri>[];
    LocalCameraRegistration? added;
    messenger.setMockMethodCallHandler(_player, (call) async {
      if (call.method == 'open') {
        opened.add(Uri.parse(call.arguments['uri'] as String));
        return opened.length;
      }
      if (call.method == 'state') {
        return {
          'failed': call.arguments['id'] == 1,
          'rendered': call.arguments['id'] == 2,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_player, null));

    final rtspOnly = _nvt.copyWith(
      connectionType: CameraConnectionType.rtsp,
      displayName: 'Kamera 192.168.1.9',
      openPorts: {554},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LocalCameraSetupScreen(
          discovery: _Discovery(
            results: [
              [rtspOnly],
            ],
          ),
          onSave: (camera) async {
            added = camera;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('192.168.1.9'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Podgląd na żywo'), findsOneWidget);
    expect(opened, hasLength(2));
    expect(opened.first.host, '192.168.1.9');
    expect(opened.first, isNot(opened.last));
    expect(added, isNull);
    await tester.tap(find.text('Dodaj kamerę'));
    await tester.pumpAndSettle();
    expect(added?.connection.rtspUri, opened.last);
    expect(added?.camera.connectionType, CameraConnectionType.rtsp);
  });

  testWidgets('checks the detected camera before asking for its login', (
    tester,
  ) async {
    await _largeScreen(tester);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final resolutions = <MethodCall>[];
    LocalCameraRegistration? added;
    messenger.setMockMethodCallHandler(_player, (call) async {
      if (call.method == 'resolveOnvif') {
        resolutions.add(call);
        if (resolutions.length == 1) {
          throw PlatformException(code: 'cameraAuth');
        }
        return 'rtsp://admin:example@192.168.1.9/live';
      }
      return switch (call.method) {
        'open' => 1,
        'state' => {'rendered': true, 'failed': false},
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_player, null));
    await tester.pumpWidget(
      MaterialApp(
        home: LocalCameraSetupScreen(
          discovery: _Discovery(
            results: [
              [_nvt],
            ],
          ),
          onSave: (camera) async {
            added = camera;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('ONVIF'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('192.168.1.9'));
    await tester.pumpAndSettle();
    expect(resolutions.single.arguments, {
      'endpoint': _nvt.onvifServiceUrl,
      'username': '',
      'password': '',
    });
    await tester.enterText(
      find.widgetWithText(TextField, 'Użytkownik kamery'),
      'admin',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Hasło kamery'),
      'example',
    );
    await tester.tap(find.text('Połącz z kamerą'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(resolutions.last.arguments['username'], 'admin');
    expect(find.text('Podgląd na żywo'), findsOneWidget);
    await tester.tap(find.text('Dodaj kamerę'));
    await tester.pumpAndSettle();
    expect(added?.camera.connectionType, CameraConnectionType.onvif);
    expect(added?.camera.onvifServiceUrl, _nvt.onvifServiceUrl);
  });

  testWidgets('sets up a nearby camera and searches home Wi-Fi on its own', (
    tester,
  ) async {
    await _largeScreen(tester);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_pairing, (call) async {
      calls.add(call);
      return switch (call.method) {
        'scan' => {
          'fresh': true,
          'homeSsid': 'Dom',
          'networks': [
            {
              'ssid': 'robot0df2',
              'bssid': '00:11:22:33:44:55',
              'security': 'open',
            },
            {
              'ssid': 'OtherNetwork',
              'bssid': '00:11:22:33:44:66',
              'security': 'wpa2',
            },
          ],
        },
        'inspectDvrip' => 'Kamera XMEye (DVRIP)',
        'configure' => 'UNCONFIRMED',
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_pairing, null));
    final other = _nvt.copyWith(
      deviceId: 'other',
      displayName: 'Druga kamera',
      ipAddress: '192.168.1.10',
    );
    final discovery = _Discovery(
      results: [
        [other],
        [other, _nvt],
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LocalCameraSetupScreen(
          discovery: discovery,
          onSave: (_) async => fail('The image must be confirmed separately'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Połącz nową kamerę z Wi‑Fi'));
    await tester.pumpAndSettle();
    expect(find.text('OtherNetwork'), findsNothing);
    await tester.tap(find.text('robot0df2'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), [
      'scan',
      'connect',
      'inspectDvrip',
    ]);
    expect(find.text('Dom'), findsOneWidget);
    expect(find.textContaining('DVRIP'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextField, 'Hasło domowego Wi-Fi'),
      'test-wifi-123',
    );
    await tester.tap(find.text('Połącz kamerę z Wi‑Fi'));
    await tester.pumpAndSettle();
    expect(discovery.scans, 2);
    final candidate = find.text('Nowa w sieci · 192.168.1.9');
    expect(candidate, findsOneWidget);
    expect(
      tester.getTopLeft(candidate).dy,
      lessThan(tester.getTopLeft(find.text('Druga kamera')).dy),
    );
    expect(calls.where((call) => call.method == 'configure'), hasLength(1));
  });

  testWidgets(
    'unconfirmed BLE advances to LAN verification without resending',
    (tester) async {
      await _largeScreen(tester);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_reolink, (call) async {
        calls.add(call);
        return switch (call.method) {
          'select' => true,
          'connectWifi' => 'unconfirmed',
          'prepareStream' => throw PlatformException(code: 'notFoundLan'),
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_reolink, null));
      messenger.setMockMethodCallHandler(_pairing, (call) async {
        return call.method == 'scan' ? {'fresh': true, 'networks': []} : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_pairing, null));
      await tester.pumpWidget(
        MaterialApp(
          home: LocalCameraSetupScreen(
            discovery: _Discovery(),
            onSave: (_) async => fail('No verified preview to save'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Połącz nową kamerę z Wi‑Fi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mam kod z etykiety kamery'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '9527000nbaka1h1u');
      await tester.tap(find.text('Znajdź kamerę'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Dom');
      await tester.enterText(find.byType(TextField).at(1), 'WifiExample9');
      await tester.tap(find.text('Połącz kamerę z Wi-Fi'));
      await tester.pumpAndSettle();
      expect(find.textContaining('bez potwierdzenia'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'CameraTest1');
      await tester.tap(find.text('Znajdź kamerę i pokaż obraz'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nie widzę tej kamery'), findsOneWidget);
      expect(calls.where((call) => call.method == 'connectWifi'), hasLength(1));
      expect(
        calls.singleWhere((call) => call.method == 'prepareStream').arguments,
        {'uid': '9527000NBAKA1H1U', 'password': 'CameraTest1', 'factory': true},
      );
    },
  );
}
