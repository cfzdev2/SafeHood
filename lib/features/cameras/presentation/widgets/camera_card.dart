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

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black87,
                child: const Center(
                  child: Icon(
                    Icons.videocam_outlined,
                    color: Colors.white70,
                    size: 48,
                  ),
                ),
              ),
            ),
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
