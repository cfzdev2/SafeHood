import 'package:flutter/material.dart';

import '../../domain/camera.dart';

enum CameraCardStatus {
  monitoringActive,
  monitoringDisabled,
  monitoringConnecting,
  bridgeOffline,
  monitoringUnavailable,
}

class CameraCard extends StatelessWidget {
  final Camera camera;
  final CameraCardStatus? status;
  final VoidCallback? onTap;

  const CameraCard({super.key, required this.camera, this.status, this.onTap});

  @override
  Widget build(BuildContext context) {
    final effectiveStatus =
        status ??
        (camera.motionDetectionEnabled
            ? CameraCardStatus.monitoringUnavailable
            : CameraCardStatus.monitoringDisabled);

    final statusColor = _statusColor(context, effectiveStatus);

    final availabilityColor = camera.isOnline
        ? Colors.green
        : Theme.of(context).colorScheme.error;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(aspectRatio: 16 / 9, child: _buildPreview(context)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          camera.name,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(camera.locationName),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.circle,
                              size: 8,
                              color: availabilityColor,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                camera.isOnline
                                    ? 'Kamera online'
                                    : 'Kamera offline',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: availabilityColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 135,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Icon(Icons.circle, size: 10, color: statusColor),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _statusLabel(effectiveStatus),
                            maxLines: 2,
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final snapshotUrl = camera.latestSnapshotUrl?.trim();

    if (snapshotUrl == null || snapshotUrl.isEmpty) {
      return _buildPreviewPlaceholder();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          snapshotUrl,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) {
              return child;
            }

            return _buildPreviewPlaceholder(loading: true);
          },
          errorBuilder: (_, _, _) {
            return _buildPreviewPlaceholder();
          },
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _snapshotLabel(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewPlaceholder({bool loading = false}) {
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              )
            : const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.videocam_outlined,
                    color: Colors.white70,
                    size: 48,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Brak ostatniego snapshotu',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
      ),
    );
  }

  String _snapshotLabel(BuildContext context) {
    final eventType = _eventTypeLabel(camera.latestEventType);
    final snapshotAt = camera.latestSnapshotAt;

    if (snapshotAt == null) {
      return eventType;
    }

    final localDate = snapshotAt.toLocal();
    final localizations = MaterialLocalizations.of(context);

    final date = localizations.formatShortDate(localDate);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(localDate),
      alwaysUse24HourFormat: true,
    );

    return '$eventType • $date, $time';
  }

  String _eventTypeLabel(String? type) {
    switch (type) {
      case 'person':
        return 'Wykryto osobę';

      case 'vehicle':
        return 'Wykryto pojazd';

      case 'motion':
        return 'Wykryto ruch';

      case 'sound':
        return 'Wykryto dźwięk';

      case 'tampering':
        return 'Naruszenie kamery';

      default:
        return 'Ostatnie zdarzenie';
    }
  }

  String _statusLabel(CameraCardStatus status) {
    switch (status) {
      case CameraCardStatus.monitoringActive:
        return 'Monitoring aktywny';

      case CameraCardStatus.monitoringDisabled:
        return 'Monitoring wyłączony';

      case CameraCardStatus.monitoringConnecting:
        return 'Łączenie monitoringu';

      case CameraCardStatus.bridgeOffline:
        return 'Bridge offline';

      case CameraCardStatus.monitoringUnavailable:
        return 'Brak monitoringu';
    }
  }

  Color _statusColor(BuildContext context, CameraCardStatus status) {
    switch (status) {
      case CameraCardStatus.monitoringActive:
        return Colors.green;

      case CameraCardStatus.monitoringDisabled:
        return Colors.orange;

      case CameraCardStatus.monitoringConnecting:
        return Colors.blue;

      case CameraCardStatus.bridgeOffline:
        return Colors.orange;

      case CameraCardStatus.monitoringUnavailable:
        return Theme.of(context).colorScheme.error;
    }
  }
}
