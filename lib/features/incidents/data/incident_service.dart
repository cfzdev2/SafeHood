import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/incident.dart';

class IncidentService {
  final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  final FirebaseAuth _auth =
      FirebaseAuth.instance;

  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(
    region: 'europe-central2',
  );

  CollectionReference<Map<String, dynamic>>
      get _incidents {
    return _firestore.collection('incidents');
  }

  Stream<List<Incident>> watchIncidents() {
    final user = _auth.currentUser;

    if (user == null) {
      return Stream.value([]);
    }

    return _incidents
        .where(
          'participantIds',
          arrayContains: user.uid,
        )
        .snapshots()
        .map((snapshot) {
      final incidents = snapshot.docs
          .map(
            (document) =>
                Incident.fromMap(
              document.id,
              document.data(),
            ),
          )
          .toList();

      incidents.sort(
        (a, b) =>
            b.createdAt.compareTo(
          a.createdAt,
        ),
      );

      return incidents;
    });
  }

  Stream<List<Incident>> watchMyIncidents() {
    return watchIncidents();
  }

  Stream<List<IncidentResponse>> watchResponses(
    String incidentId,
  ) {
    final user = _auth.currentUser;

    if (user == null) {
      return Stream.value([]);
    }

    return _incidents
        .doc(incidentId)
        .collection('responses')
        .snapshots()
        .map((snapshot) {
      final responses = snapshot.docs
          .map(
            (document) =>
                IncidentResponse.fromMap(
              document.id,
              document.data(),
            ),
          )
          .toList();

      responses.sort(
        (a, b) =>
            b.updatedAt.compareTo(
          a.updatedAt,
        ),
      );

      return responses;
    });
  }

  Future<void> setResponse({
    required String incidentId,
    required IncidentResponseStatus status,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw StateError(
        'Użytkownik nie jest zalogowany.',
      );
    }

    final callable =
        _functions.httpsCallable(
      'setIncidentResponse',
    );

    await callable.call({
      'incidentId': incidentId,
      'status': status.name,
    });
  }

  Future<IncidentContact> getIncidentContact(
    String incidentId,
  ) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw StateError(
        'Użytkownik nie jest zalogowany.',
      );
    }

    final callable =
        _functions.httpsCallable(
      'getIncidentContact',
    );

    final result = await callable.call({
      'incidentId': incidentId,
    });

    final rawData = result.data;

    if (rawData is! Map) {
      throw StateError(
        'Backend zwrócił '
        'nieprawidłową odpowiedź.',
      );
    }

    final data =
        Map<String, dynamic>.from(
      rawData,
    );

    final reporterName =
        data['reporterName'] as String?;

    final phoneNumber =
        data['phoneNumber'] as String?;

    if (phoneNumber == null ||
        phoneNumber.trim().isEmpty) {
      throw StateError(
        'Brak numeru telefonu '
        'zgłaszającego.',
      );
    }

    return IncidentContact(
      reporterName:
          reporterName ?? 'Użytkownik',
      phoneNumber: phoneNumber,
    );
  }

  Future<Incident> createIncident({
    required String cameraId,
    required String cameraName,
    required String title,
    String? description,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw StateError(
        'Użytkownik nie jest zalogowany.',
      );
    }

    final callable =
        _functions.httpsCallable(
      'createIncident',
    );

    final result = await callable.call({
      'cameraId': cameraId,
      'title': title,
      'description':
          description?.trim() ?? '',
    });

    final rawData = result.data;

    if (rawData is! Map) {
      throw StateError(
        'Backend zwrócił '
        'nieprawidłową odpowiedź.',
      );
    }

    final data =
        Map<String, dynamic>.from(
      rawData,
    );

    final createdAtMillis =
        (data['createdAtMillis'] as num?)
            ?.toInt();

    final expiresAtMillis =
        (data['expiresAtMillis'] as num?)
            ?.toInt();

    if (createdAtMillis == null ||
        expiresAtMillis == null) {
      throw StateError(
        'Backend nie zwrócił '
        'czasu zgłoszenia.',
      );
    }

    final rawParticipantIds =
        data['participantIds'];

    final participantIds =
        rawParticipantIds is List
            ? rawParticipantIds
                .whereType<String>()
                .toList()
            : <String>[user.uid];

    return Incident(
      id: data['id'] as String? ?? '',
      reporterId:
          data['reporterId'] as String? ??
              user.uid,
      reporterName:
          data['reporterName'] as String? ??
              'Użytkownik',
      cameraId:
          data['cameraId'] as String? ??
              cameraId,
      cameraName:
          data['cameraName'] as String? ??
              cameraName,
      title:
          data['title'] as String? ??
              title,
      description:
          data['description'] as String?,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(
        createdAtMillis,
      ),
      expiresAt:
          DateTime.fromMillisecondsSinceEpoch(
        expiresAtMillis,
      ),
      status: IncidentStatus.active,
      hasRecording: false,
      participantIds: participantIds,
    );
  }
}