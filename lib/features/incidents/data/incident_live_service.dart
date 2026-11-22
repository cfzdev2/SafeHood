import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class IncidentLiveFrame {
  const IncidentLiveFrame(this.jpeg, this.validUntil);

  final Uint8List jpeg;
  final DateTime validUntil;
}

class IncidentLiveService {
  static const maximumFrameBytes = 96 * 1024;
  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-central2');

  Stream<IncidentLiveFrame?> watch(String incidentId) => _db
      .collection('incidents')
      .doc(incidentId)
      .collection('live')
      .doc('current')
      .snapshots(includeMetadataChanges: true)
      .map((document) {
        if (document.metadata.isFromCache) return null;
        final data = document.data();
        final jpeg = data?['jpeg'];
        final lease = data?['leaseUntil'];
        if (jpeg is! Blob || lease is! Timestamp) return null;
        final bytes = jpeg.bytes;
        if (bytes.length > maximumFrameBytes || bytes.length < 4) return null;
        return IncidentLiveFrame(bytes, lease.toDate());
      });

  Future<String> start(String incidentId) async {
    final result = await _call(incidentId, 'start');
    final sessionId = result['sessionId'];
    if (sessionId is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(sessionId)) {
      throw StateError('Brak sesji transmisji.');
    }
    return sessionId;
  }

  Future<void> send(String incidentId, String sessionId, Uint8List jpeg) async {
    if (jpeg.length > maximumFrameBytes || jpeg.length < 4) {
      throw ArgumentError('Nieprawidłowa klatka transmisji.');
    }
    await _call(
      incidentId,
      'frame',
      sessionId: sessionId,
      jpeg: base64Encode(jpeg),
    );
  }

  Future<void> stop(String incidentId, String sessionId) =>
      _call(incidentId, 'stop', sessionId: sessionId);

  Future<Map<String, dynamic>> _call(
    String incidentId,
    String action, {
    String? sessionId,
    String? jpeg,
  }) async {
    final result = await _functions
        .httpsCallable(
          'updateIncidentLive',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 8)),
        )
        .call<Map<String, dynamic>>({
          'incidentId': incidentId,
          'action': action,
          'sessionId': ?sessionId,
          'jpeg': ?jpeg,
        });
    return result.data;
  }
}
