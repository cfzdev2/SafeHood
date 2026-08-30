import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/bridge_status.dart';

class BridgeStatusCard extends StatefulWidget {
  final BridgeStatus? bridge;
  final bool isLoading;
  final Object? error;

  const BridgeStatusCard({
    super.key,
    required this.bridge,
    required this.isLoading,
    required this.error,
  });

  @override
  State<BridgeStatusCard> createState() => _BridgeStatusCardState();
}

class _BridgeStatusCardState extends State<BridgeStatusCard> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();

    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bridge = widget.bridge;

    if (widget.isLoading && bridge == null) {
      return _buildCard(
        context: context,
        icon: Icons.sync,
        title: 'Sprawdzanie Bridge',
        subtitle: 'Pobieranie aktualnego statusu...',
        trailing: const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (widget.error != null && bridge == null) {
      return _buildCard(
        context: context,
        icon: Icons.cloud_off_outlined,
        iconColor: Theme.of(context).colorScheme.error,
        title: 'Nie udało się sprawdzić Bridge',
        subtitle: 'Sprawdź połączenie z Firestore.',
      );
    }

    if (bridge == null) {
      return _buildCard(
        context: context,
        icon: Icons.hub_outlined,
        title: 'Bridge nie jest skonfigurowany',
        subtitle: 'Dodaj lub uruchom urządzenie SafeHood Bridge.',
      );
    }

    final now = DateTime.now();

    final isOnline = bridge.isOnlineAt(now);

    final color = isOnline
        ? Colors.green.shade600
        : Theme.of(context).colorScheme.error;

    return _buildCard(
      context: context,
      icon: isOnline ? Icons.hub : Icons.hub_outlined,
      iconColor: color,
      title: isOnline ? 'Bridge online' : 'Bridge offline',
      subtitle: isOnline
          ? '${bridge.name} • '
                '${_cameraCountLabel(bridge.activeCameraCount)}'
          : _offlineDescription(bridge, now),
      trailing: Icon(Icons.circle, size: 12, color: color),
    );
  }

  Widget _buildCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    Color? iconColor,
    Widget? trailing,
  }) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: trailing,
      ),
    );
  }

  String _offlineDescription(BridgeStatus bridge, DateTime now) {
    final age = bridge.ageAt(now);

    if (age == null) {
      return 'Brak informacji '
          'o ostatnim kontakcie.';
    }

    if (age.isNegative || age < const Duration(seconds: 30)) {
      return 'Ostatni kontakt: '
          'przed chwilą';
    }

    if (age < const Duration(minutes: 2)) {
      return 'Ostatni kontakt: '
          '${age.inSeconds} s temu';
    }

    if (age < const Duration(hours: 2)) {
      return 'Ostatni kontakt: '
          '${age.inMinutes} min temu';
    }

    return 'Ostatni kontakt: '
        '${age.inHours} godz. temu';
  }

  String _cameraCountLabel(int count) {
    if (count == 1) {
      return '1 aktywna kamera';
    }

    final lastDigit = count % 10;
    final lastTwoDigits = count % 100;

    if (lastDigit >= 2 &&
        lastDigit <= 4 &&
        (lastTwoDigits < 12 || lastTwoDigits > 14)) {
      return '$count aktywne kamery';
    }

    return '$count aktywnych kamer';
  }
}
