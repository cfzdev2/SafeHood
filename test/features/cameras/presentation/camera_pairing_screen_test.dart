import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/presentation/camera_pairing_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('safehood/camera_hotspot_pairing');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('sends home Wi-Fi only after checking the selected camera', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'scan' => {
          'fresh': true,
          'homeSsid': 'Dom',
          'networks': [
            {
              'ssid': 'TestCamera',
              'bssid': '00:11:22:33:44:55',
              'security': 'open',
            },
          ],
        },
        'inspect' => 'Test NVT',
        'configure' => 'UNCONFIRMED',
        _ => null,
      };
    });

    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => const CameraPairingScreen(),
                  ),
                );
              },
              child: const Text('Otwórz kreator'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Otwórz kreator'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wyszukaj sieć kamery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TestCamera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Połącz z siecią kamery'));
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.method), ['scan', 'connect', 'inspect']);
    expect(calls[1].arguments, {'bssid': '00:11:22:33:44:55', 'password': ''});
    expect(find.text('Kamera: Test NVT'), findsOneWidget);
    expect(find.text('Dom'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Hasło domowego Wi-Fi'),
      'test-wifi-123',
    );
    await tester.tap(find.text('Przekaż dane Wi-Fi kamerze'));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'configure');
    expect(calls.last.arguments, {'ssid': 'Dom', 'password': 'test-wifi-123'});
    expect(
      find.textContaining('Nie otrzymaliśmy potwierdzenia'),
      findsOneWidget,
    );
    expect(find.text('Kamera przyjęła konfigurację.'), findsNothing);

    await tester.tap(find.text('Wykryj kamerę w sieci domowej'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(calls.where((call) => call.method == 'configure'), hasLength(1));
  });

  testWidgets('does not request home Wi-Fi if ONVIF cannot configure it', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspect') {
        throw PlatformException(code: 'noOnvifWifi');
      }
      return call.method == 'scan'
          ? {
              'fresh': true,
              'networks': [
                {
                  'ssid': 'LimitedCamera',
                  'bssid': '00:11:22:33:44:55',
                  'security': 'open',
                },
              ],
            }
          : null;
    });
    await tester.pumpWidget(const MaterialApp(home: CameraPairingScreen()));
    await tester.tap(find.text('Wyszukaj sieć kamery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LimitedCamera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Połącz z siecią kamery'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('nie udostępnia przez niego konfiguracji Wi-Fi'),
      findsOneWidget,
    );
    expect(find.text('Hasło domowego Wi-Fi'), findsNothing);
  });
}
