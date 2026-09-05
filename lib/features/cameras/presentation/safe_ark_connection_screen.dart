import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/safe_ark_cloud_gateway.dart';
import '../domain/manufacturer_cloud.dart';

class SafeArkConnectionScreen extends StatelessWidget {
  final ManufacturerCloudGateway gateway;

  const SafeArkConnectionScreen({
    super.key,
    this.gateway = const SafeArkCloudGateway(),
  });

  Future<void> _beginAccountLink(BuildContext context) async {
    try {
      final session = await gateway.beginAccountLink();

      if (!context.mounted) {
        return;
      }

      final instruction =
          session.authorizationUri?.toString() ??
          session.userCode ??
          'Rozpoczęto łączenie konta.';

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(instruction)));
    } catch (error) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorDescription(error))));
    }
  }

  String _errorDescription(Object error) {
    if (error is StateError) {
      return error.message;
    }

    return error.toString();
  }

  String _statusLabel(ManufacturerCloudAccountStatus status) {
    switch (status) {
      case ManufacturerCloudAccountStatus.unavailable:
        return 'Integracja przygotowywana';

      case ManufacturerCloudAccountStatus.disconnected:
        return 'Konto niepołączone';

      case ManufacturerCloudAccountStatus.linking:
        return 'Łączenie konta...';

      case ManufacturerCloudAccountStatus.connected:
        return 'Konto połączone';

      case ManufacturerCloudAccountStatus.expired:
        return 'Połączenie wygasło';

      case ManufacturerCloudAccountStatus.error:
        return 'Błąd połączenia';
    }
  }

  bool _canBeginLink(ManufacturerCloudAccountStatus status) {
    return status == ManufacturerCloudAccountStatus.disconnected ||
        status == ManufacturerCloudAccountStatus.expired ||
        status == ManufacturerCloudAccountStatus.error;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Połącz z SafeArk')),
      body: FutureBuilder<ManufacturerCloudAccountState>(
        future: gateway.getAccountState(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Nie udało się sprawdzić '
                  'stanu SafeArk.\n'
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final state = snapshot.data;

          if (state == null) {
            return const Center(
              child: Text(
                'Brak informacji '
                'o połączeniu SafeArk.',
              ),
            );
          }

          final canBeginLink = _canBeginLink(state.status);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 12),
              Center(
                child: CircleAvatar(
                  radius: 38,
                  child: const Icon(Icons.cloud_outlined, size: 38),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'DEKCO SafeArk',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Floodlight Camera Pro '
                'L5P/DL5P',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.info_outline),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _statusLabel(state.status),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      if (state.errorMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(state.errorMessage!),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.verified_user_outlined, size: 22),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'SafeHood nie będzie '
                        'zapisywać hasła do '
                        'SafeArk. Autoryzacja '
                        'zostanie wykonana przez '
                        'bezpieczny mechanizm '
                        'producenta.',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: canBeginLink
                    ? () {
                        _beginAccountLink(context);
                      }
                    : null,
                icon: const Icon(Icons.link),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('Połącz konto SafeArk'),
                ),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 12),
                Text(
                  'Tryb deweloperski',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Pozwala przetestować '
                  'formularz DEKCO bez '
                  'prawdziwego konta SafeArk.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop(true);
                  },
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Kontynuuj testowo'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
