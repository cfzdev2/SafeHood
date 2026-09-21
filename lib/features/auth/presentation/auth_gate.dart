import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../app/app_shell.dart';
import '../../profile/data/user_profile_service.dart';
import '../../profile/domain/app_user.dart';
import '../../profile/presentation/account_setup_screen.dart';
import '../data/auth_service.dart';
import 'login_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();
    final profileService = UserProfileService();

    return StreamBuilder<User?>(
      stream: authService.authStateChanges,
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

        return StreamBuilder<AppUser?>(
          stream: profileService.watchProfile(firebaseUser.uid),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const _ProfileLoadingScreen();
            }

            if (profileSnapshot.hasError) {
              return Scaffold(
                body: Center(
                  child: Text(
                    'Błąd profilu: '
                    '${profileSnapshot.error}',
                  ),
                ),
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
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 20),
                Text(
                  'Łączenie z profilem...',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                Text(
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
