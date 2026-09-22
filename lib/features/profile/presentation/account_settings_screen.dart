import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../auth/data/auth_service.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  final currentPasswordController = TextEditingController();
  final newPasswordController = TextEditingController();
  final repeatPasswordController = TextEditingController();

  final authService = AuthService();

  bool isLoading = false;

  @override
  void dispose() {
    currentPasswordController.dispose();
    newPasswordController.dispose();
    repeatPasswordController.dispose();
    super.dispose();
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> changePassword() async {
    final currentPassword = currentPasswordController.text;
    final newPassword = newPasswordController.text;
    final repeatPassword = repeatPasswordController.text;

    if (currentPassword.isEmpty ||
        newPassword.isEmpty ||
        repeatPassword.isEmpty) {
      showMessage('Uzupełnij wszystkie pola.');

      return;
    }

    if (newPassword.length < 6) {
      showMessage('Nowe hasło musi mieć co najmniej 6 znaków.');

      return;
    }

    if (newPassword != repeatPassword) {
      showMessage('Nowe hasła nie są takie same.');

      return;
    }

    if (newPassword == currentPassword) {
      showMessage('Nowe hasło musi być inne niż obecne.');

      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      isLoading = true;
    });

    try {
      await authService.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );

      if (!mounted) return;

      currentPasswordController.clear();
      newPasswordController.clear();
      repeatPasswordController.clear();

      showMessage('Hasło zostało zmienione.');
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;

      debugPrint(
        'AUTH CHANGE PASSWORD ERROR: '
        '${error.code} | ${error.message}',
      );

      String message;

      switch (error.code) {
        case 'invalid-credential':
        case 'wrong-password':
          message = 'Obecne hasło jest nieprawidłowe.';
          break;

        case 'weak-password':
          message = 'Nowe hasło jest zbyt słabe.';
          break;

        case 'network-request-failed':
          message = 'Brak połączenia. Spróbuj ponownie.';
          break;

        case 'too-many-requests':
          message = 'Zbyt wiele prób. Spróbuj ponownie później.';
          break;

        case 'requires-recent-login':
        case 'user-token-expired':
          message = 'Sesja wygasła. Wyloguj się i zaloguj ponownie.';
          break;

        default:
          message = 'Nie udało się zmienić hasła. Spróbuj ponownie.';
      }

      showMessage(message);
    } catch (error) {
      if (!mounted) return;

      debugPrint('AUTH CHANGE PASSWORD ERROR: $error');

      showMessage('Nie udało się zmienić hasła. Spróbuj ponownie.');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = authService.currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia konta')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('E-mail'),
              subtitle: Text(user?.email ?? 'Brak adresu e-mail'),
              trailing: Icon(
                user?.emailVerified == true
                    ? Icons.verified_outlined
                    : Icons.warning_amber_outlined,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Zmień hasło',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: currentPasswordController,
            enabled: !isLoading,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Obecne hasło',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: newPasswordController,
            enabled: !isLoading,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Nowe hasło',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.password_outlined),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: repeatPasswordController,
            enabled: !isLoading,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Powtórz nowe hasło',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.password_outlined),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: isLoading ? null : changePassword,
            icon: isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.lock_reset),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('Zmień hasło'),
            ),
          ),
        ],
      ),
    );
  }
}
