import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
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

  Future<void> showDeleteAccountDialog() async {
    String currentPassword = '';
    String confirmation = '';

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isDeleting = false;
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            void showDeletionError(String message) {
              if (!dialogContext.mounted) return;

              setDialogState(() {
                isDeleting = false;
                errorMessage = message;
              });
            }

            Future<void> deleteAccount() async {
              if (currentPassword.isEmpty) {
                showDeletionError('Podaj aktualne hasło.');
                return;
              }

              if (confirmation.trim() != 'USUŃ') {
                showDeletionError('Wpisz dokładnie USUŃ.');
                return;
              }

              setDialogState(() {
                isDeleting = true;
                errorMessage = null;
              });

              try {
                await authService.deleteAccount(
                  currentPassword: currentPassword,
                );

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              } on FirebaseAuthException catch (error) {
                debugPrint(
                  'AUTH DELETE ACCOUNT ERROR: '
                  '${error.code} | ${error.message}',
                );

                String message;

                switch (error.code) {
                  case 'invalid-credential':
                  case 'wrong-password':
                    message = 'Aktualne hasło jest nieprawidłowe.';
                    break;

                  case 'network-request-failed':
                    message = 'Brak połączenia. Spróbuj ponownie.';
                    break;

                  case 'too-many-requests':
                    message = 'Zbyt wiele prób. Spróbuj ponownie później.';
                    break;

                  default:
                    message = 'Nie udało się potwierdzić hasła.';
                }

                showDeletionError(message);
              } on FirebaseFunctionsException catch (error) {
                debugPrint(
                  'FUNCTION DELETE ACCOUNT ERROR: '
                  '${error.code} | ${error.message}',
                );

                String message;

                switch (error.code) {
                  case 'failed-precondition':
                    message = 'Potwierdź ponownie swoje hasło.';
                    break;

                  case 'permission-denied':
                    message = 'Najpierw zweryfikuj adres e-mail.';
                    break;

                  case 'unauthenticated':
                    message = 'Sesja wygasła. Zaloguj się ponownie.';
                    break;

                  case 'unavailable':
                  case 'deadline-exceeded':
                    message = 'Usługa jest chwilowo niedostępna.';
                    break;

                  default:
                    message = 'Nie udało się usunąć konta.';
                }

                showDeletionError(message);
              } catch (error) {
                debugPrint('DELETE ACCOUNT ERROR: $error');

                showDeletionError(
                  'Nie udało się usunąć konta. Spróbuj ponownie.',
                );
              }
            }

            return AlertDialog(
              title: const Text('Usunąć konto?'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Ta operacja jest nieodwracalna. Usunięte zostaną '
                      'konto, profil, kamery, Bridge, zdarzenia oraz '
                      'pozostałe dane SafeHood.',
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      enabled: !isDeleting,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      onChanged: (value) {
                        currentPassword = value;
                      },
                      decoration: const InputDecoration(
                        labelText: 'Aktualne hasło',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      enabled: !isDeleting,
                      autocorrect: false,
                      onChanged: (value) {
                        confirmation = value;
                      },
                      decoration: const InputDecoration(
                        labelText: 'Wpisz USUŃ',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isDeleting
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                        },
                  child: const Text('Anuluj'),
                ),
                FilledButton(
                  onPressed: isDeleting ? null : deleteAccount,
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: isDeleting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Usuń konto'),
                ),
              ],
            );
          },
        );
      },
    );
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
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          Text(
            'Strefa niebezpieczna',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text('Usunięcie konta i jego danych jest nieodwracalne.'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: isLoading ? null : showDeleteAccountDialog,
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              side: BorderSide(color: Theme.of(context).colorScheme.error),
            ),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('Usuń konto'),
            ),
          ),
        ],
      ),
    );
  }
}
