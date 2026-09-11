import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/camera.dart';
import '../domain/camera_notification_settings.dart';

class CameraService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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

  Future<void> addCamera(Camera camera) async {
    final userRef = _firestore.collection('users').doc(_uid);

    final document = _camerasCollection.doc();

    await _firestore.runTransaction<void>((transaction) async {
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

  Future<void> deleteCamera(String cameraId) {
    return _camerasCollection.doc(cameraId).delete();
  }
}
