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
            Future<void> signOut() =>
                authService.logout(cleanupTimeout: const Duration(seconds: 3));

            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return ProfileConnectionScreen(onSignOut: signOut);
            }

            if (profileSnapshot.hasError) {
              return ProfileConnectionScreen(
                loadFailed: true,
                onSignOut: signOut,
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

class ProfileConnectionScreen extends StatefulWidget {
  const ProfileConnectionScreen({
    super.key,
    this.loadFailed = false,
    required this.onSignOut,
  });

  final bool loadFailed;
  final Future<void> Function() onSignOut;

  @override
  State<ProfileConnectionScreen> createState() =>
      _ProfileConnectionScreenState();
}

class _ProfileConnectionScreenState extends State<ProfileConnectionScreen> {
  bool _signingOut = false;

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await widget.onSignOut();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się wylogować. Spróbuj ponownie.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

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
                if (!widget.loadFailed) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                ],
                Text(
                  widget.loadFailed
                      ? 'Nie udało się wczytać profilu.'
                      : 'Łączenie z profilem...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sprawdź połączenie. Jeżeli profil się nie otwiera, '
                  'zaloguj się ponownie.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _signingOut ? null : _signOut,
                  child: Text(
                    _signingOut ? 'Wylogowuję…' : 'Zaloguj się ponownie',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
