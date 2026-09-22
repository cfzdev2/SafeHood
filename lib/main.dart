import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/services/push_notification_service.dart';
import 'firebase_options.dart';

const _useFirebaseEmulators = bool.fromEnvironment(
  'USE_FIREBASE_EMULATORS',
  defaultValue: false,
);

const _firebaseEmulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '',
);

Future<void> _configureFirebaseBackend() async {
  if (!_useFirebaseEmulators) {
    debugPrint('FIREBASE: backend chmurowy');

    return;
  }

  if (!kDebugMode) {
    throw StateError(
      'Emulatory Firebase są dozwolone wyłącznie w trybie debug.',
    );
  }

  final emulatorHost = _firebaseEmulatorHost.trim();

  if (emulatorHost.isEmpty) {
    throw StateError(
      'Podaj FIREBASE_EMULATOR_HOST, gdy '
      'USE_FIREBASE_EMULATORS=true.',
    );
  }
  await FirebaseAuth.instance.useAuthEmulator(
    emulatorHost,
    9099,
    automaticHostMapping: false,
  );

  final firestore = FirebaseFirestore.instance;

  firestore.useFirestoreEmulator(emulatorHost, 8080);
  firestore.settings = const Settings(persistenceEnabled: false);

  FirebaseFunctions.instanceFor(
    region: 'europe-central2',
  ).useFunctionsEmulator(emulatorHost, 5001);

  debugPrint('FIREBASE: emulatory na $emulatorHost');
}

String? _normalizedPushText(Object? value) {
  if (value is! String) {
    return null;
  }

  final normalized = value.trim();

  if (normalized.isEmpty) {
    return null;
  }

  return normalized;
}

bool _canOpenPush(RemoteMessage message) {
  final type = _normalizedPushText(message.data['type']);

  switch (type) {
    case 'camera_event':
      return _normalizedPushText(message.data['eventId']) != null &&
          _normalizedPushText(message.data['cameraId']) != null;

    case 'incident':
    case 'incident_chat':
    case 'incident_response':
      return _normalizedPushText(message.data['incidentId']) != null;

    default:
      return false;
  }
}

void _showForegroundPush(RemoteMessage message) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final messenger = rootScaffoldMessengerKey.currentState;

    if (messenger == null) {
      debugPrint(
        'PUSH FOREGROUND: '
        'brak ScaffoldMessenger',
      );

      return;
    }

    final title =
        _normalizedPushText(message.notification?.title) ??
        'Nowe powiadomienie';

    final body = _normalizedPushText(message.notification?.body);

    final canOpen = _canOpenPush(message);

    messenger.removeCurrentSnackBar();

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        showCloseIcon: true,
        content: Row(
          children: [
            Expanded(child: Text(body == null ? title : '$title\n$body')),
            if (canOpen) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  messenger.hideCurrentSnackBar();

                  PushNotificationService.instance
                      .handleForegroundMessageAction(message);
                },
                style: TextButton.styleFrom(
                  foregroundColor: Colors.lightBlueAccent,
                ),
                child: const Text('ZOBACZ'),
              ),
            ],
          ],
        ),
      ),
    );
  });
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  debugPrint(
    'PUSH BACKGROUND: '
    '${message.notification?.title}',
  );

  debugPrint(
    'PUSH BACKGROUND DATA: '
    '${message.data}',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _configureFirebaseBackend();

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  FirebaseMessaging.onMessage.listen(
    (message) {
      debugPrint(
        'PUSH MAIN FOREGROUND: '
        '${message.notification?.title}',
      );

      debugPrint(
        'PUSH MAIN DATA: '
        '${message.data}',
      );

      _showForegroundPush(message);
    },
    onError: (Object error) {
      debugPrint(
        'PUSH MAIN FOREGROUND ERROR: '
        '$error',
      );
    },
  );

  debugPrint(
    'PUSH MAIN: listener foreground '
    'zarejestrowany',
  );

  runApp(const SafeHoodApp());

  unawaited(PushNotificationService.instance.initialize());
}
