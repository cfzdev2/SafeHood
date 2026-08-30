import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/camera_event.dart';

class CameraEventEscalationResult {
  final String incidentId;
  final bool alreadyEscalated;

  const CameraEventEscalationResult({
    required this.incidentId,
    required this.alreadyEscalated,
  });
}

class CameraEventIngestResult {
  final String eventId;
  final String type;
  final bool merged;
  final int occurrenceCount;

  const CameraEventIngestResult({
    required this.eventId,
    required this.type,
    required this.merged,
    required this.occurrenceCount,
  });
}

class CameraEventService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  CameraEventService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseFunctions? functions,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _functions =
           functions ??
           FirebaseFunctions.instanceFor(region: 'europe-central2');

  CollectionReference<Map<String, dynamic>> get _events {
    return _firestore.collection('cameraEvents');
  }

  String _requireUid() {
    final user = _auth.currentUser;

    if (user == null) {
      throw StateError('Użytkownik nie jest zalogowany.');
    }

    return user.uid;
  }

  Stream<List<CameraEvent>> watchMyEvents({int limit = 100}) {
    final uid = _requireUid();

    return _events.where('ownerId', isEqualTo: uid).snapshots().map((snapshot) {
      final events = snapshot.docs
          .map((doc) => CameraEvent.fromMap(id: doc.id, map: doc.data()))
          .toList();

      events.sort((a, b) => b.lastOccurredAt.compareTo(a.lastOccurredAt));

      if (events.length <= limit) {
        return events;
      }

      return events.take(limit).toList();
    });
  }

  Stream<List<CameraEvent>> watchCameraEvents({
    required String cameraId,
    int limit = 50,
  }) {
    final uid = _requireUid();

    return _events.where('ownerId', isEqualTo: uid).snapshots().map((snapshot) {
      final events = snapshot.docs
          .map((doc) => CameraEvent.fromMap(id: doc.id, map: doc.data()))
          .where((event) => event.cameraId == cameraId)
          .toList();

      events.sort((a, b) => b.lastOccurredAt.compareTo(a.lastOccurredAt));

      if (events.length <= limit) {
        return events;
      }

      return events.take(limit).toList();
    });
  }

  Stream<CameraEvent?> watchEvent(String eventId) {
    final uid = _requireUid();

    return _events.doc(eventId).snapshots().map((snapshot) {
      if (!snapshot.exists) {
        return null;
      }

      final data = snapshot.data();

      if (data == null) {
        return null;
      }

      final event = CameraEvent.fromMap(id: snapshot.id, map: data);

      if (event.ownerId != uid) {
        return null;
      }

      return event;
    });
  }

  Future<CameraEvent?> getEvent(String eventId) async {
    final uid = _requireUid();

    final snapshot = await _events.doc(eventId).get();

    if (!snapshot.exists) {
      return null;
    }

    final data = snapshot.data();

    if (data == null) {
      return null;
    }

    final event = CameraEvent.fromMap(id: snapshot.id, map: data);

    if (event.ownerId != uid) {
      return null;
    }

    return event;
  }

  Future<void> markViewed(String eventId) async {
    final uid = _requireUid();

    final ref = _events.doc(eventId);

    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);

      if (!snapshot.exists) {
        throw StateError('Wykrycie nie istnieje.');
      }

      final data = snapshot.data();

      if (data == null) {
        throw StateError('Brak danych wykrycia.');
      }

      if (data['ownerId'] != uid) {
        throw StateError('Brak dostępu do wykrycia.');
      }

      final status = data['status'] as String?;

      if (status != 'new') {
        return;
      }

      transaction.update(ref, {
        'status': 'viewed',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> dismiss(String eventId) async {
    final uid = _requireUid();

    final ref = _events.doc(eventId);

    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);

      if (!snapshot.exists) {
        throw StateError('Wykrycie nie istnieje.');
      }

      final data = snapshot.data();

      if (data == null) {
        throw StateError('Brak danych wykrycia.');
      }

      if (data['ownerId'] != uid) {
        throw StateError('Brak dostępu do wykrycia.');
      }

      final status = data['status'] as String?;

      if (status == 'escalated') {
        throw StateError(
          'Wykrycie zostało już '
          'powiązane ze zgłoszeniem.',
        );
      }

      if (status == 'dismissed') {
        return;
      }

      transaction.update(ref, {
        'status': 'dismissed',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<CameraEventIngestResult> ingestFromCamera({
    required String cameraId,
    required String type,
    String source = 'unknown',
    double? confidence,
    String? snapshotUrl,
    String? clipUrl,
    DateTime? occurredAt,
  }) async {
    _requireUid();

    final normalizedCameraId = cameraId.trim();

    final normalizedType = type.trim().toLowerCase();

    if (normalizedCameraId.isEmpty) {
      throw ArgumentError('Brak identyfikatora kamery.');
    }

    if (normalizedType.isEmpty) {
      throw ArgumentError('Brak typu wykrycia.');
    }

    final callable = _functions.httpsCallable('ingestCameraEvent');

    final response = await callable.call<Map<String, dynamic>>({
      'cameraId': normalizedCameraId,
      'type': normalizedType,
      'source': source.trim().isEmpty ? 'unknown' : source.trim(),
      'confidence': ?confidence,
      if (snapshotUrl != null && snapshotUrl.trim().isNotEmpty)
        'snapshotUrl': snapshotUrl.trim(),
      if (clipUrl != null && clipUrl.trim().isNotEmpty)
        'clipUrl': clipUrl.trim(),
      if (occurredAt != null)
        'occurredAt': occurredAt.toUtc().toIso8601String(),
    });

    final data = response.data;

    final eventId = data['id'] as String?;

    if (eventId == null || eventId.isEmpty) {
      throw StateError(
        'Backend nie zwrócił '
        'identyfikatora wykrycia.',
      );
    }

    return CameraEventIngestResult(
      eventId: eventId,
      type: data['type'] as String? ?? normalizedType,
      merged: data['merged'] == true,
      occurrenceCount: data['occurrenceCount'] as int? ?? 1,
    );
  }

  Future<CameraEventEscalationResult> escalate({
    required String eventId,
    required String title,
    String description = '',
  }) async {
    _requireUid();

    final callable = _functions.httpsCallable('escalateCameraEvent');

    final response = await callable.call<Map<String, dynamic>>({
      'eventId': eventId,
      'title': title.trim(),
      'description': description.trim(),
    });

    final data = response.data;

    final incidentId = data['id'] as String?;

    if (incidentId == null || incidentId.isEmpty) {
      throw StateError(
        'Backend nie zwrócił '
        'identyfikatora zgłoszenia.',
      );
    }

    return CameraEventEscalationResult(
      incidentId: incidentId,
      alreadyEscalated: data['alreadyEscalated'] == true,
    );
  }
}
