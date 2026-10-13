import 'package:flutter/material.dart';

import '../../domain/bridge_diagnostics.dart';

class BridgeDiagnosticsPanel extends StatelessWidget {
  final BridgeDiagnostics? diagnostics;
  final bool bridgeOnline;

  const BridgeDiagnosticsPanel({
    super.key,
    required this.diagnostics,
    required this.bridgeOnline,
  });

  @override
  Widget build(BuildContext context) {
    final diagnostics = this.diagnostics;
    final now = DateTime.now();
    final health = bridgeOnline && diagnostics != null
        ? diagnostics.healthAt(now)
        : BridgeDiagnosticHealth.unknown;
    final color = _healthColor(context, health);

    if (diagnostics == null) {
      return _statusOnly(
        context,
        color: color,
        icon: Icons.monitor_heart_outlined,
        title: 'Brak diagnostyki',
        subtitle: bridgeOnline
            ? 'Raport pojawi się po aktualizacji Bridge.'
            : 'Uruchom Bridge, aby sprawdzić pracę AI.',
      );
    }

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        leading: Icon(_healthIcon(health), color: color),
        title: Text(
          _healthTitle(health),
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(_healthDescription(health, diagnostics)),
        children: [
          _detailRow(
            context,
            label: 'Sesje AI',
            value:
                '${diagnostics.aiRunningSessions}/${diagnostics.aiExpectedSessions} aktywnych',
          ),
          _detailRow(
            context,
            label: 'Analiza obrazu',
            value:
                '${diagnostics.framesAnalyzed} klatek, '
                '${diagnostics.droppedFramePercent}% pominiętych',
          ),
          _detailRow(
            context,
            label: 'Kolejki',
            value:
                '${diagnostics.pendingUploads} wysyłki, '
                '${diagnostics.pendingInference} oczekuje na AI',
          ),
          _detailRow(
            context,
            label: 'Błędy',
            value:
                '${diagnostics.inferenceErrors} analizy, '
                '${diagnostics.eventErrors} zdarzeń',
          ),
          _detailRow(
            context,
            label: 'Pamięć Bridge',
            value: '${diagnostics.rssMebibytes.toStringAsFixed(0)} MiB',
          ),
          _detailRow(
            context,
            label: 'Ostatnia klatka',
            value: _lastFrameDescription(diagnostics, now),
          ),
        ],
      ),
    );
  }

  Widget _statusOnly(
    BuildContext context, {
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle),
    );
  }

  Widget _detailRow(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Color _healthColor(BuildContext context, BridgeDiagnosticHealth health) {
    switch (health) {
      case BridgeDiagnosticHealth.healthy:
        return Colors.green.shade700;
      case BridgeDiagnosticHealth.degraded:
        return Colors.orange.shade800;
      case BridgeDiagnosticHealth.problem:
        return Theme.of(context).colorScheme.error;
      case BridgeDiagnosticHealth.idle:
      case BridgeDiagnosticHealth.unknown:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }

  IconData _healthIcon(BridgeDiagnosticHealth health) {
    switch (health) {
      case BridgeDiagnosticHealth.healthy:
        return Icons.check_circle_outline;
      case BridgeDiagnosticHealth.degraded:
        return Icons.speed_outlined;
      case BridgeDiagnosticHealth.problem:
        return Icons.error_outline;
      case BridgeDiagnosticHealth.idle:
        return Icons.pause_circle_outline;
      case BridgeDiagnosticHealth.unknown:
        return Icons.help_outline;
    }
  }

  String _healthTitle(BridgeDiagnosticHealth health) {
    switch (health) {
      case BridgeDiagnosticHealth.healthy:
        return 'AI działa prawidłowo';
      case BridgeDiagnosticHealth.degraded:
        return 'AI pracuje z ograniczeniami';
      case BridgeDiagnosticHealth.problem:
        return 'AI wymaga uwagi';
      case BridgeDiagnosticHealth.idle:
        return 'AI jest nieaktywne';
      case BridgeDiagnosticHealth.unknown:
        return 'Brak aktualnej diagnostyki';
    }
  }

  String _healthDescription(
    BridgeDiagnosticHealth health,
    BridgeDiagnostics diagnostics,
  ) {
    switch (health) {
      case BridgeDiagnosticHealth.healthy:
        return 'Strumienie, analiza i kolejki działają poprawnie.';
      case BridgeDiagnosticHealth.degraded:
        return 'Duża część klatek jest pomijana lub kolejka rośnie.';
      case BridgeDiagnosticHealth.problem:
        if (diagnostics.aiRunningSessions < diagnostics.aiExpectedSessions) {
          return 'Nie uruchomiono wszystkich wymaganych sesji AI.';
        }

        if (diagnostics.aiStalledSessions > 0) {
          return 'Co najmniej jedna sesja AI nie otrzymuje klatek.';
        }

        return 'Jedna z kolejek osiągnęła bezpieczny limit.';
      case BridgeDiagnosticHealth.idle:
        return 'Żadna kamera nie korzysta teraz z lokalnego AI.';
      case BridgeDiagnosticHealth.unknown:
        return 'Ostatni raport jest starszy niż 90 sekund.';
    }
  }

  String _lastFrameDescription(BridgeDiagnostics diagnostics, DateTime now) {
    final age = diagnostics.lastFrameAgeAt(now);

    if (age == null) {
      return diagnostics.aiExpectedSessions == 0
          ? 'AI nieaktywne'
          : 'Brak klatek';
    }

    if (age < 2) {
      return 'przed chwilą';
    }

    if (age < 60) {
      return '$age s temu';
    }

    return '${age ~/ 60} min temu';
  }
}
