import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/app_user.dart';
import 'package:geoflutterfire_plus/geoflutterfire_plus.dart';

class UserProfileService {
  final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _userDocument(
    String uid,
  ) {
    return _firestore.collection('users').doc(uid);
  }

  Stream<AppUser?> watchProfile(String uid) {
    return _userDocument(uid).snapshots().map(
      (snapshot) {
        final data = snapshot.data();

        if (!snapshot.exists || data == null) {
          return null;
        }

        return AppUser.fromMap(
          snapshot.id,
          data,
        );
      },
    );
  }

  Future<void> saveProfile(AppUser profile) async {
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

    Map<String, dynamic>? geoData;

    if (profile.latitude != null &&
        profile.longitude != null) {
      final geoPoint = GeoFirePoint(
        GeoPoint(
          profile.latitude!,
          profile.longitude!,
        ),
      );

      geoData = geoPoint.data;
    }

    await _userDocument(profile.id).set({
      ...profile.toMap(),
      'email': firebaseUser.email,
      'geo': geoData,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}