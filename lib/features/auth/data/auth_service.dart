import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/push_notification_service.dart';

class AuthService {
  final FirebaseAuth _auth =
      FirebaseAuth.instance;

  Stream<User?> get authStateChanges {
    return _auth.authStateChanges();
  }

  User? get currentUser {
    return _auth.currentUser;
  }

  Future<UserCredential> register({
    required String email,
    required String password,
  }) async {
    final credential =
        await _auth
            .createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

    final user =
        credential.user;

    if (user != null) {
      await PushNotificationService
          .instance
          .registerCurrentDevice(
        uid: user.uid,
      );
    }

    return credential;
  }

  Future<UserCredential> login({
    required String email,
    required String password,
  }) async {
    final credential =
        await _auth
            .signInWithEmailAndPassword(
      email: email,
      password: password,
    );

    final user =
        credential.user;

    if (user != null) {
      await PushNotificationService
          .instance
          .registerCurrentDevice(
        uid: user.uid,
      );
    }

    return credential;
  }

  Future<void> logout() async {
    final user =
        _auth.currentUser;

    if (user != null) {
      await PushNotificationService
          .instance
          .unregisterCurrentDevice(
        uid: user.uid,
      );
    }

    await _auth.signOut();
  }
}