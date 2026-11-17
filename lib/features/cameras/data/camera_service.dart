import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'local_camera_connection.dart';

import '../domain/camera.dart';
import '../domain/camera_ai_zone.dart';
import '../domain/camera_notification_settings.dart';

class CameraService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'europe-central2',
  );

  String get _uid {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw StateError('Użytkownik nie jest zalogowany.');
    }

    return user.uid;
  }

  CollectionReference<Map<String, dynamic>> get _camerasCollection {
    return _firestore.collection('users').doc(_uid).collection('cameras');
  }

  Stream<List<Camera>> watchCameras() {
    return _camerasCollection.snapshots().map((snapshot) {
      return snapshot.docs
          .map((document) => Camera.fromMap(document.id, document.data()))
          .toList();
    });
  }

  Future<Camera?> getCamera(String cameraId) async {
    final document = await _camerasCollection.doc(cameraId).get();

    if (!document.exists) {
      return null;
    }

    final data = document.data();

    if (data == null) {
      return null;
    }

    return Camera.fromMap(document.id, data);
  }

  Future<void> addCamera(
    Camera camera, {
    LocalCameraConnection connection = const LocalCameraConnection(),
    String? legacyId,
  }) async {
    final userId = _uid;
    final userRef = _firestore.collection('users').doc(userId);

    if (legacyId != null && !RegExp(r'^[a-f0-9-]{36}$').hasMatch(legacyId)) {
      throw ArgumentError('Nieprawidłowy identyfikator zapisanej kamery.');
    }
    final document = userRef
        .collection('cameras')
        .doc(legacyId == null ? null : 'local-$legacyId');
    // Retry the same import if removing the old entry failed. Never replace
    // an existing camera's settings or device credentials on that retry.
    if (legacyId != null &&
        (await document.get(const GetOptions(source: Source.server))).exists) {
      return;
    }

    const store = LocalCameraConnectionStore();
    if (!connection.isEmpty) await store.save(userId, document.id, connection);

    try {
      await _firestore.runTransaction<void>((transaction) async {
        if (legacyId != null && (await transaction.get(document)).exists) {
          return;
        }
        final userSnapshot = await transaction.get(userRef);

        final userData = userSnapshot.data();

        final activeBridgeValue = userData?['activeBridgeId'];

        final activeBridgeId =
            activeBridgeValue is String && activeBridgeValue.trim().isNotEmpty
            ? activeBridgeValue.trim()
            : null;

        final cameraData = camera.toMap();

        if (camera.connectionType == CameraConnectionType.onvif &&
            activeBridgeId != null) {
          cameraData['monitoringMode'] = CameraMonitoringMode.bridge.name;

          cameraData['bridgeId'] = activeBridgeId;

          cameraData['bridgeAssignedAt'] = FieldValue.serverTimestamp();

          cameraData['bridgeMonitoringStatus'] = camera.motionDetectionEnabled
              ? CameraMonitoringRuntimeStatus.connecting.name
              : CameraMonitoringRuntimeStatus.offline.name;
        }

        transaction.set(document, {
          ...cameraData,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (_) {
      if (!connection.isEmpty) {
        try {
          await store.delete(userId, document.id);
        } catch (_) {
          debugPrint(
            'Nie udało się usunąć lokalnych danych niedodanej kamery.',
          );
        }
      }
      rethrow;
    }
  }

  Future<void> saveLocalCameraConnection(
    String cameraId,
    LocalCameraConnection connection,
  ) => const LocalCameraConnectionStore().save(_uid, cameraId, connection);

  Future<void> updateCameraDetails({
    required String cameraId,
    required String name,
    required String locationName,
  }) {
    final normalizedName = name.trim();
    final normalizedLocationName = locationName.trim();

    if (normalizedName.isEmpty) {
      throw ArgumentError('Nazwa kamery nie może być pusta.');
    }

    if (normalizedLocationName.isEmpty) {
      throw ArgumentError('Lokalizacja kamery nie może być pusta.');
    }

    if (normalizedName.length > 60) {
      throw ArgumentError('Nazwa kamery może mieć maksymalnie 60 znaków.');
    }

    if (normalizedLocationName.length > 100) {
      throw ArgumentError('Lokalizacja może mieć maksymalnie 100 znaków.');
    }

    return _camerasCollection.doc(cameraId).update({
      'name': normalizedName,
      'locationName': normalizedLocationName,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setMonitoringEnabled({
    required String cameraId,
    required bool enabled,
  }) {
    return _camerasCollection.doc(cameraId).update({
      'motionDetectionEnabled': enabled,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setAiSettings({
    required String cameraId,
    required bool enabled,
    required bool personEnabled,
    required bool vehicleEnabled,
    required String sensitivity,
    bool? recordingEnabled,
  }) {
    const allowedSensitivities = {'low', 'standard', 'high'};

    if (!allowedSensitivities.contains(sensitivity)) {
      throw ArgumentError('Nieprawidłowa czułość AI.');
    }

    if (enabled && !personEnabled && !vehicleEnabled) {
      throw ArgumentError('Włącz co najmniej jeden typ wykrywania AI.');
    }

    return _camerasCollection.doc(cameraId).update({
      'aiEnabled': enabled,
      'aiPersonEnabled': personEnabled,
      'aiVehicleEnabled': vehicleEnabled,
      'aiSensitivity': sensitivity,
      'aiRecordingEnabled': ?recordingEnabled,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setAiZones({
    required String cameraId,
    required List<CameraAiZone> detectionZones,
    required List<CameraAiZone> ignoreZones,
  }) {
    _validateAiZones(detectionZones);
    _validateAiZones(ignoreZones);

    return _camerasCollection.doc(cameraId).update({
      'aiDetectionZones': detectionZones.map((zone) => zone.toMap()).toList(),
      'aiIgnoreZones': ignoreZones.map((zone) => zone.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  void _validateAiZones(List<CameraAiZone> zones) {
    if (zones.length > CameraAiZone.maximumZonesPerType ||
        zones.any((zone) => !zone.isValid)) {
      throw ArgumentError('Nieprawidłowe strefy analizy AI.');
    }
  }

  Future<CameraNotificationSettings> getNotificationSettings(
    String cameraId,
  ) async {
    final document = await _camerasCollection.doc(cameraId).get();

    if (!document.exists) {
      throw StateError('Kamera nie istnieje.');
    }

    final data = document.data();

    return CameraNotificationSettings.fromMap(data?['notificationSettings']);
  }

  Future<void> setNotificationSettings({
    required String cameraId,
    required CameraNotificationSettings settings,
  }) {
    return _camerasCollection.doc(cameraId).update({
      'notificationSettings': settings.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateCameraAvailability({
    required String cameraId,
    required bool isOnline,
  }) {
    return _camerasCollection.doc(cameraId).update({
      'isOnline': isOnline,
      'availabilityCheckedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteCamera(String cameraId) async {
    final normalizedCameraId = cameraId.trim();

    if (normalizedCameraId.isEmpty) {
      throw ArgumentError('Brak identyfikatora kamery.');
    }

    final userId = _uid;
    final callable = _functions.httpsCallable('deleteCamera');

    await callable.call<void>({'cameraId': normalizedCameraId});
    try {
      await const LocalCameraConnectionStore().delete(
        userId,
        normalizedCameraId,
      );
    } catch (_) {
      debugPrint('Nie udało się usunąć lokalnych danych kamery.');
    }
  }
}
