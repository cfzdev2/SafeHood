import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class PushNavigationTarget {
  final String incidentId;
  final bool openChat;

  const PushNavigationTarget({
    required this.incidentId,
    required this.openChat,
  });
}

class CameraEventPushNavigationTarget {
  final String eventId;
  final String cameraId;

  const CameraEventPushNavigationTarget({
    required this.eventId,
    required this.cameraId,
  });
}

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  final FirebaseInstallations _installations = FirebaseInstallations.instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final FirebaseAuth _auth = FirebaseAuth.instance;

  final ValueNotifier<PushNavigationTarget?> pendingNavigation =
      ValueNotifier<PushNavigationTarget?>(null);

  final ValueNotifier<CameraEventPushNavigationTarget?>
  pendingCameraEventNavigation =
      ValueNotifier<CameraEventPushNavigationTarget?>(null);

  StreamSubscription<String>? _fidSubscription;

  StreamSubscription<String>? _tokenSubscription;

  StreamSubscription<RemoteMessage>? _openedMessageSubscription;

  bool _initialized = false;

  bool get _isSupportedPlatform {
    if (kIsWeb) {
      return false;
    }

    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<void> initialize() async {
    if (_initialized || !_isSupportedPlatform) {
      return;
    }

    _initialized = true;

    debugPrint('PUSH: inicjalizacja');

    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      debugPrint(
        'PUSH: permission = '
        '${settings.authorizationStatus.name}',
      );

      final fcmToken = await _messaging.getToken();

      debugPrint(
        'PUSH: FCM registration = '
        '${fcmToken != null ? "OK" : "BRAK"}',
      );

      final currentUser = _auth.currentUser;

      if (currentUser != null) {
        await registerCurrentDevice(
          uid: currentUser.uid,
          tokenOverride: fcmToken,
        );
      }

      _tokenSubscription = _messaging.onTokenRefresh.listen(
        (token) async {
          debugPrint('PUSH: token FCM zmienił się');

          final user = _auth.currentUser;

          if (user == null) {
            return;
          }

          await registerCurrentDevice(uid: user.uid, tokenOverride: token);
        },
        onError: (Object error) {
          debugPrint('PUSH TOKEN ERROR: $error');
        },
      );

      _fidSubscription = _installations.onIdChange.listen(
        (fid) async {
          debugPrint('PUSH: FID zmienił się');

          final user = _auth.currentUser;

          if (user == null) {
            return;
          }

          final token = await _messaging.getToken();

          await registerCurrentDevice(
            uid: user.uid,
            fidOverride: fid,
            tokenOverride: token,
          );
        },
        onError: (Object error) {
          debugPrint('PUSH FID ERROR: $error');
        },
      );

      _openedMessageSubscription = FirebaseMessaging.onMessageOpenedApp.listen((
        message,
      ) {
        debugPrint(
          'PUSH OPENED BACKGROUND: '
          '${message.data}',
        );

        _handleOpenedMessage(message);
      });

      final initialMessage = await _messaging.getInitialMessage();

      if (initialMessage != null) {
        debugPrint(
          'PUSH OPENED TERMINATED: '
          '${initialMessage.data}',
        );

        _handleOpenedMessage(initialMessage);
      }

      debugPrint('PUSH: inicjalizacja zakończona');
    } catch (error, stackTrace) {
      debugPrint('PUSH INIT ERROR: $error');

      debugPrint(
        'PUSH INIT STACKTRACE: '
        '$stackTrace',
      );
    }
  }

  void handleForegroundMessageAction(RemoteMessage message) {
    debugPrint(
      'PUSH FOREGROUND ACTION: '
      '${message.data}',
    );

    _handleOpenedMessage(message);
  }

  void _handleOpenedMessage(RemoteMessage message) {
    final type = message.data['type']?.trim();

    if (type == 'camera_event') {
      final eventId = message.data['eventId']?.trim();

      final cameraId = message.data['cameraId']?.trim();

      if (eventId == null || eventId.isEmpty) {
        debugPrint('PUSH CAMERA EVENT: brak eventId');

        return;
      }

      if (cameraId == null || cameraId.isEmpty) {
        debugPrint('PUSH CAMERA EVENT: brak cameraId');

        return;
      }

      debugPrint(
        'PUSH CAMERA EVENT: '
        'otwieram event $eventId',
      );

      pendingCameraEventNavigation.value = CameraEventPushNavigationTarget(
        eventId: eventId,
        cameraId: cameraId,
      );

      return;
    }

    final incidentId = message.data['incidentId']?.trim();

    if (incidentId == null || incidentId.isEmpty) {
      debugPrint('PUSH: brak incidentId');

      return;
    }

    switch (type) {
      case 'incident_chat':
        pendingNavigation.value = PushNavigationTarget(
          incidentId: incidentId,
          openChat: true,
        );
        break;

      case 'incident':
      case 'incident_response':
        pendingNavigation.value = PushNavigationTarget(
          incidentId: incidentId,
          openChat: false,
        );
        break;

      default:
        debugPrint('PUSH: nieobsługiwany typ: $type');
    }
  }

  void clearPendingNavigation(String incidentId) {
    final current = pendingNavigation.value;

    if (current?.incidentId == incidentId) {
      pendingNavigation.value = null;
    }
  }

  void clearPendingCameraEventNavigation(String eventId) {
    final current = pendingCameraEventNavigation.value;

    if (current?.eventId == eventId) {
      pendingCameraEventNavigation.value = null;
    }
  }

  Future<void> registerCurrentDevice({
    String? uid,
    String? fidOverride,
    String? tokenOverride,
  }) async {
    if (!_isSupportedPlatform) {
      return;
    }

    final currentUser = _auth.currentUser;

    final targetUid = uid ?? currentUser?.uid;

    if (targetUid == null) {
      return;
    }

    if (currentUser == null || currentUser.uid != targetUid) {
      throw StateError(
        'Nie można zarejestrować '
        'urządzenia dla innego użytkownika.',
      );
    }

    final fid = fidOverride ?? await _installations.getId();

    final fcmToken = tokenOverride ?? await _messaging.getToken();

    if (fcmToken == null || fcmToken.isEmpty) {
      throw StateError(
        'Nie udało się pobrać '
        'tokenu FCM.',
      );
    }

    final settings = await _messaging.getNotificationSettings();

    final notificationsAllowed =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;

    await _firestore
        .collection('users')
        .doc(targetUid)
        .collection('devices')
        .doc(fid)
        .set({
          'fid': fid,
          'fcmToken': fcmToken,
          'platform': defaultTargetPlatform.name,
          'notificationsAllowed': notificationsAllowed,
          'updatedAt': FieldValue.serverTimestamp(),
        });

    debugPrint('PUSH: urządzenie zapisane');

    debugPrint('PUSH: uid = $targetUid');

    debugPrint('PUSH: fid = $fid');

    debugPrint('PUSH: token FCM zapisany');

    debugPrint(
      'PUSH: notificationsAllowed = '
      '$notificationsAllowed',
    );
  }

  Future<void> unregisterCurrentDevice({String? uid}) async {
    if (!_isSupportedPlatform) {
      return;
    }

    final currentUser = _auth.currentUser;

    final targetUid = uid ?? currentUser?.uid;

    if (targetUid == null) {
      return;
    }

    if (currentUser == null || currentUser.uid != targetUid) {
      throw StateError(
        'Nie można usunąć urządzenia '
        'innego użytkownika.',
      );
    }

    final fid = await _installations.getId();

    await _firestore
        .collection('users')
        .doc(targetUid)
        .collection('devices')
        .doc(fid)
        .delete();

    debugPrint(
      'PUSH: urządzenie usunięte '
      'z konta $targetUid',
    );
  }

  Future<void> dispose() async {
    await _fidSubscription?.cancel();
    await _tokenSubscription?.cancel();

    await _openedMessageSubscription?.cancel();

    pendingNavigation.dispose();

    pendingCameraEventNavigation.dispose();

    _initialized = false;
  }
}
