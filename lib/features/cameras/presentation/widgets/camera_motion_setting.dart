import 'package:flutter/material.dart';

import '../../domain/camera_motion_preference.dart';

class CameraMotionSetting extends StatelessWidget {
  const CameraMotionSetting({
    super.key,
    required this.preference,
    required this.onChanged,
  });

  final CameraMotionPreference preference;
  final ValueChanged<CameraMotionPreference>? onChanged;

  static const _labels = {
    CameraMotionPreference.off: 'Wyłączone',
    CameraMotionPreference.history: 'Tylko historia',
    CameraMotionPreference.historyAndAlert: 'Historia i alert',
  };

  Future<void> _select(BuildContext context) async {
    final chosen = await showDialog<CameraMotionPreference>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Wykrywanie ruchu'),
        children: [
          for (final option in CameraMotionPreference.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option),
              child: Row(
                children: [
                  Icon(
                    option == preference
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_labels[option]!)),
                ],
              ),
            ),
        ],
      ),
    );
    if (context.mounted && chosen != null) onChanged?.call(chosen);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: onChanged != null,
      leading: const Icon(Icons.directions_run),
      title: const Text('Wykrywanie ruchu'),
      subtitle: Text(_labels[preference]!),
      trailing: const Icon(Icons.chevron_right),
      onTap: onChanged == null ? null : () => _select(context),
    );
  }
}
