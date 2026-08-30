import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/bridge_pairing_service.dart';

class BridgePairingScreen extends StatefulWidget {
  const BridgePairingScreen({super.key});

  @override
  State<BridgePairingScreen> createState() => _BridgePairingScreenState();
}

class _BridgePairingScreenState extends State<BridgePairingScreen> {
  late final BridgePairingService _pairingService;

  BridgePairingCode? _pairingCode;

  Timer? _countdownTimer;

  bool _isLoading = false;

  Object? _error;

  @override
  void initState() {
    super.initState();

    _pairingService = BridgePairingService();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });

    unawaited(_generateCode());
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();

    super.dispose();
  }

  Duration get _remainingTime {
    final expiresAt = _pairingCode?.expiresAt;

    if (expiresAt == null) {
      return Duration.zero;
    }

    final remaining = expiresAt.difference(DateTime.now());

    if (remaining.isNegative) {
      return Duration.zero;
    }

    return remaining;
  }

  bool get _isExpired {
    return _pairingCode != null && _remainingTime == Duration.zero;
  }

  Future<void> _generateCode() async {
    if (_isLoading) {
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await _pairingService.createPairingCode();

      if (!mounted) {
        return;
      }

      setState(() {
        _pairingCode = result;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = error;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _copyCode() async {
    final code = _pairingCode?.code;

    if (code == null || _isExpired) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: code));

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Kod parowania skopiowany.')));
  }

  String _errorDescription(Object error) {
    if (error is FirebaseFunctionsException) {
      return error.message ?? 'Nie udało się wygenerować kodu.';
    }

    return error.toString();
  }

  String _remainingTimeLabel() {
    final remaining = _remainingTime;

    final minutes = remaining.inMinutes;

    final seconds = remaining.inSeconds % 60;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final pairingCode = _pairingCode;

    return Scaffold(
      appBar: AppBar(title: const Text('Parowanie Bridge')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            Icons.hub_outlined,
            size: 72,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(
            'Połącz SafeHood Bridge',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Wpisz poniższy kod w konfiguratorze '
            'urządzenia SafeHood Bridge.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (_isLoading && pairingCode == null)
            const Center(child: CircularProgressIndicator()),
          if (_error != null && pairingCode == null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _errorDescription(_error!),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (pairingCode != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(
                      _isExpired ? 'Kod wygasł' : 'Kod parowania',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      pairingCode.code,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _isExpired
                          ? 'Wygeneruj nowy kod.'
                          : 'Kod wygaśnie za '
                                '${_remainingTimeLabel()}',
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: _isExpired ? null : _copyCode,
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Kopiuj kod'),
                    ),
                  ],
                ),
              ),
            ),
          if (_error != null && pairingCode != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorDescription(_error!),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _isLoading ? null : _generateCode,
            icon: const Icon(Icons.refresh),
            label: Text(
              pairingCode == null ? 'Spróbuj ponownie' : 'Wygeneruj nowy kod',
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Kod jest jednorazowy i działa przez '
            '10 minut. Nie udostępniaj go osobom, '
            'które nie powinny mieć dostępu do kamer.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
