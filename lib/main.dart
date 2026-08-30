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

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

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

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  FirebaseMessaging.onBackgroundMessage(
    firebaseMessagingBackgroundHandler,
  );

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
    },
    onError: (Object error) {
      debugPrint(
        'PUSH MAIN FOREGROUND ERROR: '
        '$error',
      );
    },
  );

  debugPrint(
    'PUSH MAIN: listener foreground zarejestrowany',
  );

  if (kDebugMode &&
      defaultTargetPlatform ==
          TargetPlatform.android) {
    const emulatorHost =
        '192.168.1.10';

    final firestore =
        FirebaseFirestore.instance;

    firestore.useFirestoreEmulator(
      emulatorHost,
      8080,
    );

    firestore.settings =
        const Settings(
      persistenceEnabled: false,
    );

    FirebaseFunctions.instanceFor(
      region: 'europe-central2',
    ).useFunctionsEmulator(
      emulatorHost,
      5001,
    );
  }

  runApp(
    const SafeHoodApp(),
  );

  unawaited(
    PushNotificationService.instance
        .initialize(),
  );
}