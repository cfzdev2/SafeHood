import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../data/auth_service.dart';

class EmailVerificationScreen extends StatefulWidget {
  final String email;

  const EmailVerificationScreen({required this.email, super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final AuthService _authService = AuthService();

  bool _isChecking = false;
  bool _isSending = false;
  bool _isLoggingOut = false;

  bool get _isBusy {
    return _isChecking || _isSending || _isLoggingOut;
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.of(context);

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  String _messageForError(FirebaseAuthException error) {
    switch (error.code) {
      case 'network-request-failed':
        return 'Brak połączenia. Spróbuj ponownie.';

      case 'too-many-requests':
        return 'Zbyt wiele prób. Spróbuj ponownie później.';

      case 'user-disabled':
        return 'To konto zostało wyłączone.';

      case 'user-not-found':
      case 'user-token-expired':
      case 'invalid-user-token':
        return 'Sesja wygasła. Zaloguj się ponownie.';

      default:
        return 'Nie udało się wykonać operacji. Spróbuj ponownie.';
    }
  }

  Future<void> _checkVerification() async {
    if (_isBusy) {
      return;
    }

    setState(() {
      _isChecking = true;
    });

    try {
      final isVerified = await _authService.reloadEmailVerificationStatus();

      if (!mounted) return;

      if (isVerified) {
        _showMessage('Adres e-mail został potwierdzony.');
      } else {
        _showMessage('Adres e-mail nie został jeszcze potwierdzony.');
      }
    } on FirebaseAuthException catch (error) {
      debugPrint(
        'AUTH EMAIL CHECK ERROR: '
        '${error.code} | ${error.message}',
      );

      if (!mounted) return;

      _showMessage(_messageForError(error));
    } catch (error) {
      debugPrint('AUTH EMAIL CHECK ERROR: $error');

      if (!mounted) return;

      _showMessage('Nie udało się sprawdzić adresu e-mail.');
    } finally {
      if (mounted) {
        setState(() {
          _isChecking = false;
        });
      }
    }
  }

  Future<void> _sendAgain() async {
    if (_isBusy) {
      return;
    }

    setState(() {
      _isSending = true;
    });

    try {
      await _authService.sendEmailVerification();

      if (!mounted) return;

      _showMessage('Wysłaliśmy nową wiadomość weryfikacyjną.');
    } on FirebaseAuthException catch (error) {
      debugPrint(
        'AUTH EMAIL RESEND ERROR: '
        '${error.code} | ${error.message}',
      );

      if (!mounted) return;

      _showMessage(_messageForError(error));
    } catch (error) {
      debugPrint('AUTH EMAIL RESEND ERROR: $error');

      if (!mounted) return;

      _showMessage('Nie udało się wysłać wiadomości.');
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    if (_isBusy) {
      return;
    }

    setState(() {
      _isLoggingOut = true;
    });

    try {
      await _authService.logout();
    } catch (error) {
      debugPrint('AUTH VERIFICATION LOGOUT ERROR: $error');

      if (!mounted) return;

      _showMessage('Nie udało się wylogować. Spróbuj ponownie.');
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingOut = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.email.trim();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mark_email_unread_outlined, size: 72),
                  const SizedBox(height: 20),
                  Text(
                    'Potwierdź adres e-mail',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Wysłaliśmy wiadomość z linkiem '
                    'weryfikacyjnym na adres:',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    email.isEmpty ? 'Brak adresu e-mail' : email,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Po kliknięciu linku wróć tutaj '
                    'i wybierz „Sprawdź ponownie”.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isBusy ? null : _checkVerification,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: _isChecking
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sprawdź ponownie'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _isBusy ? null : _sendAgain,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: _isSending
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Wyślij wiadomość ponownie'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _isBusy ? null : _logout,
                    child: _isLoggingOut
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Wyloguj się'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
