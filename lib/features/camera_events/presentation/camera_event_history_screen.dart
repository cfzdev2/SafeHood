import 'package:flutter/material.dart';

import '../data/camera_event_service.dart';
import '../domain/camera_event.dart';
import 'camera_event_details_screen.dart';

class CameraEventHistoryScreen extends StatelessWidget {
  final String cameraId;
  final String cameraName;

  CameraEventHistoryScreen({
    super.key,
    required this.cameraId,
    required this.cameraName,
  });

  final CameraEventService _eventService = CameraEventService();

  String _eventTitle(CameraEventType type) {
    switch (type) {
      case CameraEventType.motion:
        return 'Wykryto ruch';

      case CameraEventType.person:
        return 'Wykryto osobę';

      case CameraEventType.vehicle:
        return 'Wykryto pojazd';

      case CameraEventType.sound:
        return 'Wykryto dźwięk';

      case CameraEventType.tamper:
        return 'Manipulacja kamerą';

      case CameraEventType.cameraOffline:
        return 'Kamera offline';

      case CameraEventType.cameraOnline:
        return 'Kamera online';

      case CameraEventType.unknown:
        return 'Wykryto aktywność';
    }
  }

  IconData _eventIcon(CameraEventType type) {
    switch (type) {
      case CameraEventType.motion:
        return Icons.directions_run_outlined;

      case CameraEventType.person:
        return Icons.person_outline;

      case CameraEventType.vehicle:
        return Icons.directions_car_outlined;

      case CameraEventType.sound:
        return Icons.volume_up_outlined;

      case CameraEventType.tamper:
        return Icons.warning_amber_outlined;

      case CameraEventType.cameraOffline:
        return Icons.videocam_off_outlined;

      case CameraEventType.cameraOnline:
        return Icons.videocam_outlined;

      case CameraEventType.unknown:
        return Icons.notifications_outlined;
    }
  }

  String _statusLabel(CameraEvent event) {
    if (event.isDismissed) {
      return 'Niegroźne';
    }

    if (event.isEscalated) {
      return 'Zgłoszone';
    }

    final expiresAt = event.lastOccurredAt.add(const Duration(hours: 1));

    if (!DateTime.now().isBefore(expiresAt)) {
      return 'Archiwalne';
    }

    switch (event.status) {
      case CameraEventStatus.newEvent:
        return 'Nowe';

      case CameraEventStatus.viewed:
        return 'Obejrzane';

      case CameraEventStatus.dismissed:
        return 'Niegroźne';

      case CameraEventStatus.escalated:
        return 'Zgłoszone';
    }
  }

  IconData _statusIcon(CameraEvent event) {
    if (event.isDismissed) {
      return Icons.check_circle_outline;
    }

    if (event.isEscalated) {
      return Icons.warning_amber_outlined;
    }

    final expiresAt = event.lastOccurredAt.add(const Duration(hours: 1));

    if (!DateTime.now().isBefore(expiresAt)) {
      return Icons.history_outlined;
    }

    switch (event.status) {
      case CameraEventStatus.newEvent:
        return Icons.fiber_new_outlined;

      case CameraEventStatus.viewed:
        return Icons.visibility_outlined;

      case CameraEventStatus.dismissed:
        return Icons.check_circle_outline;

      case CameraEventStatus.escalated:
        return Icons.warning_amber_outlined;
    }
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();

    final day = local.day.toString().padLeft(2, '0');

    final month = local.month.toString().padLeft(2, '0');

    final hour = local.hour.toString().padLeft(2, '0');

    final minute = local.minute.toString().padLeft(2, '0');

    final second = local.second.toString().padLeft(2, '0');

    return '$day.$month.${local.year} '
        '$hour:$minute:$second';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historia wykryć')),
      body: StreamBuilder<List<CameraEvent>>(
        stream: _eventService.watchCameraEvents(cameraId: cameraId, limit: 100),
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
                  'Nie udało się pobrać '
                  'historii.\n\n'
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final events = snapshot.data ?? const <CameraEvent>[];

          if (events.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.history_toggle_off_outlined, size: 72),
                    const SizedBox(height: 16),
                    Text(
                      'Brak wykryć',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Nowe zdarzenia z kamery '
                      '"$cameraName" '
                      'pojawią się tutaj.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: events.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final event = events[index];

              return _CameraEventHistoryCard(
                event: event,
                eventTitle: _eventTitle(event.type),
                eventIcon: _eventIcon(event.type),
                statusLabel: _statusLabel(event),
                statusIcon: _statusIcon(event),
                dateTime: _formatDateTime(event.lastOccurredAt),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) {
                        return CameraEventDetailsScreen(eventId: event.id);
                      },
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _CameraEventHistoryCard extends StatelessWidget {
  final CameraEvent event;
  final String eventTitle;
  final IconData eventIcon;
  final String statusLabel;
  final IconData statusIcon;
  final String dateTime;
  final VoidCallback onTap;

  const _CameraEventHistoryCard({
    required this.event,
    required this.eventTitle,
    required this.eventIcon,
    required this.statusLabel,
    required this.statusIcon,
    required this.dateTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildPreview(),

              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(eventIcon, size: 20),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            eventTitle,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    Text(
                      dateTime,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),

                    const SizedBox(height: 8),

                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _InfoChip(icon: statusIcon, label: statusLabel),

                        if (event.occurrenceCount > 1)
                          _InfoChip(
                            icon: Icons.repeat,
                            label: '${event.occurrenceCount}×',
                          ),

                        if (event.clipUrl != null)
                          const _InfoChip(
                            icon: Icons.movie_outlined,
                            label: 'Nagranie',
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 4),

              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (event.hasSnapshot) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 92,
          height: 72,
          child: Image.network(
            event.snapshotUrl!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _placeholder();
            },
          ),
        ),
      );
    }

    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      width: 92,
      height: 72,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.videocam_outlined, color: Colors.white70),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
