import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/community_profile.dart';

class CommunityProfileService {
  final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  Future<void> saveCommunityProfile(
    CommunityProfile profile,
  ) async {
    final firebaseUser =
        FirebaseAuth.instance.currentUser;

    if (firebaseUser == null) {
      throw StateError(
        'Użytkownik nie jest zalogowany.',
      );
    }

    if (firebaseUser.uid != profile.id) {
      throw StateError(
        'Nieprawidłowy identyfikator użytkownika.',
      );
    }

    await _firestore
        .collection('communityProfiles')
        .doc(profile.id)
        .set(
      {
        ...profile.toMap(),
        'updatedAt':
            FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}