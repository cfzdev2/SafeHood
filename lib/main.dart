import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/services/push_notification_service.dart';
import 'firebase_options.dart';

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

    messenger.hideCurrentSnackBar();

    messenger.showSnackBar(
      SnackBar(
        content: Text(body == null ? title : '$title\n$body'),
        duration: const Duration(seconds: 8),
        action: _canOpenPush(message)
            ? SnackBarAction(
                label: 'ZOBACZ',
                onPressed: () {
                  PushNotificationService.instance
                      .handleForegroundMessageAction(message);
                },
              )
            : null,
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

  if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) {
    const emulatorHost = '192.168.1.10';

    final firestore = FirebaseFirestore.instance;

    firestore.useFirestoreEmulator(emulatorHost, 8080);

    firestore.settings = const Settings(persistenceEnabled: false);

    FirebaseFunctions.instanceFor(
      region: 'europe-central2',
    ).useFunctionsEmulator(emulatorHost, 5001);
  }

  runApp(const SafeHoodApp());

  unawaited(PushNotificationService.instance.initialize());
}
