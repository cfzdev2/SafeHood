import 'package:flutter/material.dart';

import '../../../core/state/app_state.dart';
import '../domain/app_user.dart';
import 'account_setup_screen.dart';
import '../../auth/data/auth_service.dart';

class ProfileScreen extends StatelessWidget {
  final AppState appState;

  const ProfileScreen({
    super.key,
    required this.appState,
  });


  @override
  Widget build(BuildContext context) {
    final user = appState.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const CircleAvatar(
            radius: 40,
            child: Icon(
              Icons.person,
              size: 40,
            ),
          ),

          const SizedBox(height: 16),

          Center(
            child: Text(
              user.firstName,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),

          const SizedBox(height: 24),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone_outlined),
                  title: const Text('Numer telefonu'),
                  subtitle: Text(user.phoneNumber),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.home_outlined),
                  title: const Text('Adres'),
                  subtitle: Text(user.address),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Powiadomienia'),
                  trailing: Text(
                    user.notificationsEnabled
                        ? 'Włączone'
                        : 'Wyłączone',
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          FilledButton.icon(
            onPressed: () async {
              final newUser =
                  await Navigator.of(context).push<AppUser>(
                MaterialPageRoute(
                  builder: (_) => AccountSetupScreen(
                    initialUser: user,
                  ),
                ),
              );

              if (newUser != null) {
                appState.updateCurrentUser(newUser);
              }
            },
            icon: const Icon(
              Icons.edit_outlined,
            ),
            label: const Text(
              'Edytuj profil',
            ),
          ),

          const SizedBox(height: 10),

          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Ustawienia'),
          ),

          const SizedBox(height: 10),

          OutlinedButton.icon(
            onPressed: () async {
              final shouldLogout = await showDialog<bool>(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: const Text('Wylogować się?'),
                    content: const Text(
                      'Czy na pewno chcesz wylogować się z SafeHood?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop(false);
                        },
                        child: const Text('Anuluj'),
                      ),
                      FilledButton(
                        onPressed: () {
                          Navigator.of(context).pop(true);
                        },
                        child: const Text('Wyloguj'),
                      ),
                    ],
                  );
                },
              );

              if (shouldLogout != true) {
                return;
              }

              await AuthService().logout();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Wyloguj się'),
          ),
        ],
      ),
    );
  }
}