import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../data/auth_service.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  final AuthService authService = AuthService();

  bool isLoading = false;
  bool isResettingPassword = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uzupełnij e-mail i hasło.')),
      );

      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      await authService.login(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      String message = 'Nie udało się zalogować.';

      if (e.code == 'invalid-credential') {
        message = 'Nieprawidłowy e-mail lub hasło.';
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> resetPassword() async {
    var resetEmail = emailController.text.trim();

    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Zresetuj hasło'),
          content: TextFormField(
            initialValue: resetEmail,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'E-mail',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              resetEmail = value;
            },
            onFieldSubmitted: (value) {
              Navigator.of(dialogContext).pop(value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(resetEmail);
              },
              child: const Text('Wyślij'),
            ),
          ],
        );
      },
    );

    if (!mounted || email == null) {
      return;
    }

    final normalizedEmail = email.trim();

    if (normalizedEmail.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Podaj adres e-mail.')));

      return;
    }

    setState(() {
      isResettingPassword = true;
    });

    const confirmationMessage =
        'Jeśli konto z tym adresem istnieje, '
        'wysłaliśmy instrukcję zmiany hasła.';

    var message = confirmationMessage;

    try {
      await authService.sendPasswordResetEmail(email: normalizedEmail);
    } on FirebaseAuthException catch (error) {
      if (error.code == 'invalid-email') {
        message = 'Podaj poprawny adres e-mail.';
      } else if (error.code == 'network-request-failed') {
        message = 'Brak połączenia. Spróbuj ponownie.';
      } else if (error.code == 'too-many-requests') {
        message = 'Zbyt wiele prób. Spróbuj ponownie później.';
      } else if (error.code != 'user-not-found') {
        message = 'Nie udało się wysłać instrukcji zmiany hasła.';
      }
    } catch (_) {
      message = 'Nie udało się wysłać instrukcji zmiany hasła.';
    } finally {
      if (mounted) {
        setState(() {
          isResettingPassword = false;
        });
      }
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.shield_outlined, size: 72),

                const SizedBox(height: 20),

                Text(
                  'SafeHood',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 32),

                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'E-mail',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),

                const SizedBox(height: 16),

                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Hasło',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),

                const SizedBox(height: 4),

                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: isLoading || isResettingPassword
                        ? null
                        : resetPassword,
                    child: isResettingPassword
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Nie pamiętasz hasła?'),
                  ),
                ),

                const SizedBox(height: 12),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: isLoading || isResettingPassword ? null : login,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Zaloguj się'),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                TextButton(
                  onPressed: isLoading || isResettingPassword
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RegisterScreen(),
                            ),
                          );
                        },
                  child: const Text('Nie masz konta? Zarejestruj się'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
