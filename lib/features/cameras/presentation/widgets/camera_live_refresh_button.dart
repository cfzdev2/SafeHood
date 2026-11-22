import 'package:flutter/material.dart';

import '../../data/camera_live_session.dart';

/// Reopens a local stream that is connected but displaying an unusable image.
class CameraLiveRefreshButton extends StatelessWidget {
  const CameraLiveRefreshButton({super.key, required this.session});

  final CameraLiveSession session;

  @override
  Widget build(BuildContext context) {
    if (!session.canRefresh) return const SizedBox.shrink();
    return IconButton(
      onPressed: session.refresh,
      tooltip: 'Odśwież podgląd',
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black54,
      ),
      icon: const Icon(Icons.refresh),
    );
  }
}
