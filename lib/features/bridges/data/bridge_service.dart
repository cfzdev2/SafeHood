import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/bridge_status.dart';

class BridgeService {
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

  CollectionReference<Map<String, dynamic>> get _bridgesCollection {
    return _firestore.collection('users').doc(_uid).collection('bridges');
  }

  Stream<List<BridgeStatus>> watchBridges() {
    return _bridgesCollection.snapshots().map((snapshot) {
      final bridges = snapshot.docs.map((document) {
        final data = document.data();

        return BridgeStatus(
          id: document.id,
          name: _parseString(data['name']) ?? 'SafeHood Bridge',
          status: _parseString(data['status']) ?? 'offline',
          platform: _parseString(data['platform']) ?? '',
          version: _parseString(data['version']) ?? '',
          activeCameraCount: _parseInt(data['activeCameraCount']),
          lastSeenAt: _parseDateTime(data['lastSeenAt']),
          pairedAt: _parseDateTime(data['pairedAt']),
          isActive: data['isActive'] as bool? ?? false,
        );
      }).toList();

      bridges.sort((first, second) {
        final firstTime = first.lastSeenAt?.millisecondsSinceEpoch ?? 0;

        final secondTime = second.lastSeenAt?.millisecondsSinceEpoch ?? 0;

        return secondTime.compareTo(firstTime);
      });

      return bridges;
    });
  }

  Future<int> assignCamerasToBridge(String bridgeId) async {
    final normalizedBridgeId = bridgeId.trim();

    if (normalizedBridgeId.isEmpty) {
      throw ArgumentError('Brak identyfikatora Bridge.');
    }

    final callable = _functions.httpsCallable('assignCamerasToBridge');

    final result = await callable.call({'bridgeId': normalizedBridgeId});

    final data = result.data;

    if (data is! Map) {
      throw StateError(
        'Backend zwrócił '
        'nieprawidłowe dane.',
      );
    }

    final assignedCameraCount = data['assignedCameraCount'];

    if (assignedCameraCount is! num) {
      throw StateError(
        'Backend nie zwrócił '
        'liczby kamer.',
      );
    }

    return assignedCameraCount.toInt();
  }

  Future<int> removeBridge(String bridgeId) async {
    final normalizedBridgeId = bridgeId.trim();

    if (normalizedBridgeId.isEmpty) {
      throw ArgumentError('Brak identyfikatora Bridge.');
    }

    final callable = _functions.httpsCallable('removeBridge');

    final result = await callable.call({'bridgeId': normalizedBridgeId});

    final data = result.data;

    if (data is! Map) {
      throw StateError(
        'Backend zwrócił '
        'nieprawidłowe dane.',
      );
    }

    final removedCameraCount = data['removedCameraCount'];

    if (removedCameraCount is! num) {
      throw StateError(
        'Backend nie zwrócił '
        'liczby odpiętych kamer.',
      );
    }

    return removedCameraCount.toInt();
  }

  static String? _parseString(dynamic value) {
    if (value is! String) {
      return null;
    }

    final normalized = value.trim();

    if (normalized.isEmpty) {
      return null;
    }

    return normalized;
  }

  static int _parseInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }

    return 0;
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    return null;
  }
}
