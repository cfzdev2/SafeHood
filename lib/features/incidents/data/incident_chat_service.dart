import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/incident_message.dart';

class IncidentChatService {
  final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  final FirebaseAuth _auth =
      FirebaseAuth.instance;

  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(
    region: 'europe-central2',
  );

  CollectionReference<Map<String, dynamic>>
      _messages(
    String incidentId,
  ) {
    return _firestore
        .collection('incidents')
        .doc(incidentId)
        .collection('messages');
  }

  Stream<List<IncidentMessage>> watchMessages(
    String incidentId,
  ) {
    final user = _auth.currentUser;

    if (user == null) {
      return Stream.value([]);
    }

    return _messages(incidentId)
        .orderBy('createdAt')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map(
            (document) =>
                IncidentMessage.fromMap(
              document.id,
              document.data(),
            ),
          )
          .toList();
    });
  }

  Future<void> sendMessage({
    required String incidentId,
    required String text,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw StateError(
        'Użytkownik nie jest zalogowany.',
      );
    }

    final cleanedText = text.trim();

    if (cleanedText.isEmpty) {
      return;
    }

    if (cleanedText.length > 500) {
      throw StateError(
        'Wiadomość może mieć '
        'maksymalnie 500 znaków.',
      );
    }

    final callable =
        _functions.httpsCallable(
      'sendIncidentMessage',
    );

    await callable.call({
      'incidentId': incidentId,
      'text': cleanedText,
    });
  }
}