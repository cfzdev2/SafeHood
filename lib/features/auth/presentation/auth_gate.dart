import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../app/app_shell.dart';
import '../../profile/data/user_profile_service.dart';
import '../../profile/domain/app_user.dart';
import '../../profile/presentation/account_setup_screen.dart';
import '../data/auth_service.dart';
import 'login_screen.dart';
import 'email_verification_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();
    final profileService = UserProfileService();

    return StreamBuilder<User?>(
      stream: authService.userChanges,
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final firebaseUser = authSnapshot.data;

        if (firebaseUser == null) {
          return const LoginScreen();
        }
        if (!firebaseUser.emailVerified) {
          return EmailVerificationScreen(email: firebaseUser.email ?? '');
        }

        return StreamBuilder<AppUser?>(
          stream: profileService.watchProfile(firebaseUser.uid),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const _ProfileLoadingScreen();
            }

            if (profileSnapshot.hasError) {
              return const Scaffold(
                body: Center(child: Text('Nie udało się wczytać profilu.')),
              );
            }

            final profile = profileSnapshot.data;

            if (profile == null) {
              return const AccountSetupScreen(isOnboarding: true);
            }

            return AppShell(currentUser: profile);
          },
        );
      },
    );
  }
}

class _ProfileLoadingScreen extends StatelessWidget {
  const _ProfileLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                const Text(
                  'Łączenie z profilem...',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Jeżeli trwa to dłużej, sprawdź połączenie '
                  'z internetem. Aplikacja spróbuje ponownie '
                  'automatycznie.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
