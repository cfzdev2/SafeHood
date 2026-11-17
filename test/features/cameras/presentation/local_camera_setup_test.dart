import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/local_camera_registration.dart';
import 'package:safehood/features/cameras/data/local_camera_store.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/presentation/local_camera_preview.dart';
import 'package:safehood/features/cameras/presentation/local_camera_setup_screen.dart';

const _player = MethodChannel('safehood/local_camera_player');
const _reolink = MethodChannel('safehood/reolink_pairing');

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

  testWidgets('imports the saved stream only after a frame and allows retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<LocalCameraSetupResult>(
                MaterialPageRoute<LocalCameraSetupResult>(
                  builder: (_) => LocalCameraSetupScreen(
                    savedSource: source,
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
    await tester.pumpAndSettle();
    await tester.tap(find.text('Przenieś sam podgląd RTSP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
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

  testWidgets(
    'unconfirmed BLE advances to LAN verification without resending',
    (tester) async {
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
      await tester.pumpWidget(
        MaterialApp(
          home: LocalCameraSetupScreen(
            onSave: (_) async => fail('No verified preview to save'),
          ),
        ),
      );
      await tester.tap(find.text('Reolink przez Bluetooth'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '9527000nbaka1h1u');
      await tester.tap(find.text('Znajdź kamerę po UID'));
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
