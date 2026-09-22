import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/push_notification_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Stream<User?> get authStateChanges {
    return _auth.authStateChanges();
  }

  Stream<User?> get userChanges {
    return _auth.userChanges();
  }

  User? get currentUser {
    return _auth.currentUser;
  }

  Future<UserCredential> register({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

    final user = credential.user;

    if (user != null) {
      await _sendEmailVerificationSafely(user);
      await _registerCurrentDeviceSafely(user);
    }

    return credential;
  }

  Future<UserCredential> login({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );

    final user = credential.user;

    if (user != null) {
      await _registerCurrentDeviceSafely(user);
    }

    return credential;
  }

  Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;

    if (user == null) {
      throw StateError('Użytkownik nie jest zalogowany.');
    }

    if (user.emailVerified) {
      return;
    }

    await _auth.setLanguageCode('pl');
    await user.sendEmailVerification();
  }

  Future<bool> reloadEmailVerificationStatus() async {
    final user = _auth.currentUser;

    if (user == null) {
      return false;
    }

    await user.reload();

    final refreshedUser = _auth.currentUser;

    if (refreshedUser == null || !refreshedUser.emailVerified) {
      return false;
    }

    await refreshedUser.getIdToken(true);

    return true;
  }

  Future<void> sendPasswordResetEmail({required String email}) async {
    await _auth.setLanguageCode('pl');
    await _auth.sendPasswordResetEmail(email: email);
  }

  Future<void> logout() async {
    final user = _auth.currentUser;

    if (user != null) {
      await _unregisterCurrentDeviceSafely(user);
    }

    await _auth.signOut();
  }

  Future<void> _sendEmailVerificationSafely(User user) async {
    if (user.emailVerified) {
      return;
    }

    try {
      await _auth.setLanguageCode('pl');
      await user.sendEmailVerification();
    } on FirebaseAuthException catch (error) {
      debugPrint(
        'AUTH EMAIL VERIFICATION ERROR: '
        '${error.code} | ${error.message}',
      );
    } catch (error) {
      debugPrint('AUTH EMAIL VERIFICATION ERROR: $error');
    }
  }

  Future<void> _registerCurrentDeviceSafely(User user) async {
    try {
      await PushNotificationService.instance.registerCurrentDevice(
        uid: user.uid,
      );
    } catch (error) {
      debugPrint('PUSH DEVICE REGISTER ERROR: $error');
    }
  }

  Future<void> _unregisterCurrentDeviceSafely(User user) async {
    try {
      await PushNotificationService.instance.unregisterCurrentDevice(
        uid: user.uid,
      );
    } catch (error) {
      debugPrint('PUSH DEVICE UNREGISTER ERROR: $error');
    }
  }
}
