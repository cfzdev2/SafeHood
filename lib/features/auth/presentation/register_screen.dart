import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../data/auth_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final repeatPasswordController = TextEditingController();

  final AuthService authService = AuthService();

  bool isLoading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    repeatPasswordController.dispose();
    super.dispose();
  }

  Future<void> register() async {
    final email = emailController.text.trim();
    final password = passwordController.text;
    final repeatPassword = repeatPasswordController.text;

    if (email.isEmpty || password.isEmpty || repeatPassword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uzupełnij wszystkie pola.')),
      );

      return;
    }
    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hasło musi mieć co najmniej 6 znaków.')),
      );

      return;
    }

    FocusScope.of(context).unfocus();

    if (password != repeatPassword) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Hasła nie są takie same.')));

      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      await authService.register(email: email, password: password);

      if (!mounted) return;

      Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      debugPrint(
        'AUTH REGISTER ERROR: '
        '${e.code} | ${e.message}',
      );

      String message;

      switch (e.code) {
        case 'weak-password':
          message = 'Hasło jest zbyt słabe.';
          break;

        case 'email-already-in-use':
          message = 'Konto z tym adresem e-mail już istnieje.';
          break;

        case 'invalid-email':
          message = 'Podaj poprawny adres e-mail.';
          break;

        case 'network-request-failed':
          message = 'Brak połączenia. Spróbuj ponownie.';
          break;

        case 'too-many-requests':
          message = 'Zbyt wiele prób. Spróbuj ponownie później.';
          break;

        case 'operation-not-allowed':
          message = 'Rejestracja przez e-mail jest obecnie niedostępna.';
          break;

        default:
          message = 'Nie udało się utworzyć konta. Spróbuj ponownie.';
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;

      debugPrint('AUTH REGISTER ERROR: $error');

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się utworzyć konta. Spróbuj ponownie.'),
        ),
      );
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
    return Scaffold(
      appBar: AppBar(title: const Text('Rejestracja')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Utwórz konto SafeHood',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 24),

          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'E-mail',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 16),

          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Hasło',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 16),

          TextField(
            controller: repeatPasswordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Powtórz hasło',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 24),

          FilledButton(
            onPressed: isLoading ? null : register,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Utwórz konto'),
            ),
          ),
        ],
      ),
    );
  }
}
