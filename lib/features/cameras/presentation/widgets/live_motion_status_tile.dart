import 'package:flutter/material.dart';

import '../../data/live_motion_monitor.dart';

class LiveMotionStatusTile extends StatelessWidget {
  const LiveMotionStatusTile({super.key, required this.monitor});

  final LiveMotionMonitor monitor;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: monitor,
      builder: (context, status, _) {
        if (status == LiveMotionStatus.off) return const SizedBox.shrink();
        return ListTile(
          leading: const Icon(Icons.directions_run),
          title: const Text('Ruch podczas podglądu'),
          subtitle: Text(switch (status) {
            LiveMotionStatus.waiting => 'Czekam na obraz z kamery…',
            LiveMotionStatus.watching => 'Wykrywanie jest aktywne.',
            LiveMotionStatus.unavailable =>
              'Nie można odczytać klatek z podglądu.',
            LiveMotionStatus.saving => 'Wykryto ruch. Zapisuję zdarzenie…',
            LiveMotionStatus.saved => 'Ostatnie wykrycie zapisano w historii.',
            LiveMotionStatus.saveFailed =>
              'Wykryto ruch. Nie udało się zapisać zdarzenia.',
            LiveMotionStatus.off => '',
          }),
        );
      },
    );
  }
}
