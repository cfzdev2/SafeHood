import 'package:flutter/material.dart';

import '../../data/camera_live_session.dart';
import '../../data/local_camera_connection.dart';

class CameraLivePlaceholder extends StatelessWidget {
  const CameraLivePlaceholder({super.key, required this.session, this.color});

  final CameraLiveSession session;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (session.isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: color),
            const SizedBox(height: 12),
            Text(switch (session.phase) {
              CameraLivePhase.reconnecting => 'Wznawianie podglądu…',
              CameraLivePhase.adjustingQuality =>
                'Dopasowywanie jakości obrazu…',
              _ => 'Łączenie z kamerą…',
            }, style: TextStyle(color: color)),
          ],
        ),
      );
    }

    final error = session.error;
    if (error == null) {
      return Center(child: Icon(Icons.videocam_off_outlined, color: color));
    }

    final message = switch (session.phase) {
      CameraLivePhase.retryScheduled =>
        'Brak obrazu. SafeHood ponowi połączenie automatycznie.',
      _ when error is CameraConnectionIssue => error.message,
      _ => 'Nie udało się połączyć z kamerą.',
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_outlined, color: color),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: session.retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Połącz ponownie'),
            ),
          ],
        ),
      ),
    );
  }
}
