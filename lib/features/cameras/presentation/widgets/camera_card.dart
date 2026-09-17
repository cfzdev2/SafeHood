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
    final theme = Theme.of(context);

    final effectiveStatus =
        status ??
        (camera.motionDetectionEnabled
            ? CameraCardStatus.monitoringUnavailable
            : CameraCardStatus.monitoringDisabled);

    final monitoringColor = _statusColor(context, effectiveStatus);

    final availabilityColor = camera.isOnline
        ? Colors.green
        : theme.colorScheme.error;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.videocam_outlined,
                  size: 30,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      camera.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      camera.locationName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildStatusChip(
                          context,
                          label: camera.isOnline
                              ? 'Kamera online'
                              : 'Kamera offline',
                          color: availabilityColor,
                        ),
                        _buildStatusChip(
                          context,
                          label: _statusLabel(effectiveStatus),
                          color: monitoringColor,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(
    BuildContext context, {
    required String label,
    required Color color,
  }) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
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
