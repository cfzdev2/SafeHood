import 'package:flutter/material.dart';

import '../../domain/camera_event_ai_metadata.dart';

class CameraEventAiSummary extends StatelessWidget {
  static const Map<String, int> _classOrder = {
    'person': 0,
    'bicycle': 1,
    'car': 2,
    'motorcycle': 3,
    'bus': 4,
    'truck': 5,
  };

  final CameraEventAiMetadata metadata;

  const CameraEventAiSummary({super.key, required this.metadata});

  String _classLabel(String className) {
    switch (className) {
      case 'person':
        return 'Osoby';
      case 'bicycle':
        return 'Rowery';
      case 'car':
        return 'Samochody';
      case 'motorcycle':
        return 'Motocykle';
      case 'bus':
        return 'Autobusy';
      case 'truck':
        return 'Ciężarówki';
      default:
        return 'Obiekty';
    }
  }

  IconData _classIcon(String className) {
    switch (className) {
      case 'person':
        return Icons.person_outline;
      case 'bicycle':
        return Icons.pedal_bike_outlined;
      case 'motorcycle':
        return Icons.motorcycle_outlined;
      case 'bus':
        return Icons.directions_bus_outlined;
      case 'truck':
        return Icons.local_shipping_outlined;
      case 'car':
      default:
        return Icons.directions_car_outlined;
    }
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _formatDuration(Duration value) {
    if (value.inMilliseconds < 1000) {
      return 'poniżej 1 s';
    }
    final seconds = value.inMilliseconds / 1000;
    final precision = seconds == seconds.round() ? 0 : 1;
    final formatted = seconds.toStringAsFixed(precision).replaceAll('.', ',');
    return '$formatted s';
  }

  @override
  Widget build(BuildContext context) {
    final confidence = metadata.confidencePercent;
    final classes = metadata.classCounts.entries.toList()
      ..sort(
        (first, second) => (_classOrder[first.key] ?? 99).compareTo(
          _classOrder[second.key] ?? 99,
        ),
      );

    return Semantics(
      label: 'Podsumowanie analizy AI',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_outlined),
                const SizedBox(width: 10),
                Text(
                  'Analiza AI',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in classes)
                  _ObjectChip(
                    icon: _classIcon(entry.key),
                    label: '${_classLabel(entry.key)}: ${entry.value}',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Metric(
                    label: 'Najwyższa pewność',
                    value: confidence == null ? 'Brak danych' : '$confidence%',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Metric(
                    label: 'Czas aktywności',
                    value: _formatDuration(metadata.activityDuration),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Pierwsze wykrycie: ${_formatTime(metadata.firstSeenAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 3),
            Text(
              'Ostatnie wykrycie: ${_formatTime(metadata.lastSeenAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 3),
            Text(
              'Potwierdzone na ${metadata.detectionFrameCount} klatkach',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ObjectChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ObjectChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 3),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
