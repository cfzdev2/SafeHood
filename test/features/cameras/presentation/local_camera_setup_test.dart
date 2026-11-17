import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/local_camera_store.dart';
import 'package:safehood/features/cameras/presentation/local_camera_preview.dart';
import 'package:safehood/features/cameras/presentation/local_camera_setup_screen.dart';

const _store = LocalCameraStore('guest');
const _player = MethodChannel('safehood/local_camera_player');
const _catalog = MethodChannel('safehood/local_camera_store');
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

  testWidgets('saves only after a frame and closes the foreground player', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var firstFrame = false;
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
    messenger.setMockMethodCallHandler(_catalog, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(_player, null);
      messenger.setMockMethodCallHandler(_catalog, null);
    });
    final source = LocalCameraSource(
      name: 'Kamera',
      uri: Uri.parse('rtsp://192.168.1.40/live'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => LocalCameraPreview(
                  source: source,
                  store: _store,
                  allowSave: true,
                ),
              ),
            ),
            child: const Text('Open preview'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preview'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final save = find.ancestor(
      of: find.text('Zapisz na telefonie'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    firstFrame = true;
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = calls.singleWhere((call) => call.method == 'save');
    expect(saved.arguments['scope'], 'guest');
    expect(saved.arguments['source']['uri'], source.uri.toString());
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
        const MaterialApp(home: LocalCameraSetupScreen(store: _store)),
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
