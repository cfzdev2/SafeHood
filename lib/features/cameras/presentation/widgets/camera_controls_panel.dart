import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/camera_provider.dart';

class CameraControlsPanel extends StatefulWidget {
  final CameraProvider provider;
  final CameraRuntimeState state;

  final bool audioEnabled;
  final Future<void> Function() onToggleAudio;

  const CameraControlsPanel({
    super.key,
    required this.provider,
    required this.state,
    required this.audioEnabled,
    required this.onToggleAudio,
  });

  @override
  State<CameraControlsPanel> createState() => _CameraControlsPanelState();
}

class _CameraControlsPanelState extends State<CameraControlsPanel> {
  bool _talkRequested = false;
  bool _floodlightEnabled = false;
  bool _sirenEnabled = false;

  bool _floodlightBusy = false;
  bool _sirenBusy = false;

  CameraTalkController? get _talkController {
    final provider = widget.provider;

    if (provider is CameraTalkController) {
      return provider as CameraTalkController;
    }

    return null;
  }

  CameraPtzController? get _ptzController {
    final provider = widget.provider;

    if (provider is CameraPtzController) {
      return provider as CameraPtzController;
    }

    return null;
  }

  CameraFloodlightController? get _floodlightController {
    final provider = widget.provider;

    if (provider is CameraFloodlightController) {
      return provider as CameraFloodlightController;
    }

    return null;
  }

  CameraSirenController? get _sirenController {
    final provider = widget.provider;

    if (provider is CameraSirenController) {
      return provider as CameraSirenController;
    }

    return null;
  }

  void _showError(String action, Object error) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$action: $error')));
  }

  Future<void> _startTalk() async {
    final controller = _talkController;

    if (controller == null) {
      return;
    }

    if (_talkRequested) {
      return;
    }

    _talkRequested = true;

    if (mounted) {
      setState(() {});
    }

    try {
      await controller.startTalk();

      // Jeśli użytkownik puścił przycisk
      // przed zakończeniem startTalk,
      // natychmiast zatrzymujemy mikrofon.
      if (!_talkRequested) {
        await controller.stopTalk();
      }
    } catch (error) {
      _talkRequested = false;

      if (mounted) {
        setState(() {});
      }

      _showError('Nie udało się uruchomić mikrofonu', error);
    }
  }

  Future<void> _stopTalk() async {
    final controller = _talkController;

    if (controller == null) {
      return;
    }

    if (!_talkRequested) {
      return;
    }

    _talkRequested = false;

    if (mounted) {
      setState(() {});
    }

    try {
      await controller.stopTalk();
    } catch (error) {
      _showError('Nie udało się zatrzymać mikrofonu', error);
    }
  }

  Future<void> _nudgePtz(CameraPtzDirection direction) async {
    final controller = _ptzController;

    if (controller == null) {
      return;
    }

    try {
      await controller.movePtz(direction);

      await Future<void>.delayed(const Duration(milliseconds: 350));
    } catch (error) {
      _showError('Nie udało się obrócić kamery', error);
    } finally {
      try {
        await controller.stopPtz();
      } catch (error) {
        _showError('Nie udało się zatrzymać PTZ', error);
      }
    }
  }

  Future<void> _setFloodlight(bool enabled) async {
    final controller = _floodlightController;

    if (controller == null) {
      return;
    }

    if (_floodlightBusy) {
      return;
    }

    final previousValue = _floodlightEnabled;

    setState(() {
      _floodlightBusy = true;
      _floodlightEnabled = enabled;
    });

    try {
      await controller.setFloodlight(enabled);
    } catch (error) {
      if (mounted) {
        setState(() {
          _floodlightEnabled = previousValue;
        });
      }

      _showError('Nie udało się zmienić reflektora', error);
    } finally {
      if (mounted) {
        setState(() {
          _floodlightBusy = false;
        });
      }
    }
  }

  Future<void> _setSiren(bool enabled) async {
    final controller = _sirenController;

    if (controller == null) {
      return;
    }

    if (_sirenBusy) {
      return;
    }

    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Włączyć syrenę?'),
            content: const Text(
              'Kamera uruchomi głośny alarm. '
              'Upewnij się, że nie przestraszy '
              'osób znajdujących się w pobliżu.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop(false);
                },
                child: const Text('Anuluj'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop(true);
                },
                child: const Text('Włącz'),
              ),
            ],
          );
        },
      );

      if (confirmed != true || !mounted) {
        return;
      }
    }

    final previousValue = _sirenEnabled;

    setState(() {
      _sirenBusy = true;
      _sirenEnabled = enabled;
    });

    try {
      await controller.setSiren(enabled);
    } catch (error) {
      if (mounted) {
        setState(() {
          _sirenEnabled = previousValue;
        });
      }

      _showError('Nie udało się zmienić syreny', error);
    } finally {
      if (mounted) {
        setState(() {
          _sirenBusy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    final talkController = _talkController;

    final sirenController = _sirenController;

    final ptzController = _ptzController;

    if (_talkRequested && talkController != null) {
      unawaited(talkController.stopTalk());
    }

    if (_sirenEnabled && sirenController != null) {
      unawaited(sirenController.setSiren(false));
    }

    if (ptzController != null) {
      unawaited(ptzController.stopPtz());
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = widget.provider.capabilities;

    final isOnline = widget.state.isOnline;

    final hasPrimaryControls =
        capabilities.supportsAudio || capabilities.supportsTalk;

    final hasAdvancedControls =
        capabilities.supportsPtz ||
        capabilities.supportsFloodlight ||
        capabilities.supportsSiren;

    if (!hasPrimaryControls && !hasAdvancedControls) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        if (hasPrimaryControls)
          Row(
            children: [
              if (capabilities.supportsAudio)
                Expanded(
                  child: _ControlButton(
                    icon: widget.audioEnabled
                        ? Icons.volume_up_outlined
                        : Icons.volume_off_outlined,
                    label: widget.audioEnabled ? 'Dźwięk' : 'Wyciszony',
                    active: widget.audioEnabled,
                    onTap: isOnline
                        ? () {
                            unawaited(widget.onToggleAudio());
                          }
                        : null,
                  ),
                ),
              if (capabilities.supportsAudio && capabilities.supportsTalk)
                const SizedBox(width: 12),
              if (capabilities.supportsTalk)
                Expanded(
                  child: _ControlButton(
                    icon: _talkRequested ? Icons.mic : Icons.mic_outlined,
                    label: _talkRequested
                        ? 'Mówisz...'
                        : 'Przytrzymaj, '
                              'aby mówić',
                    active: _talkRequested,
                    onTap: isOnline ? () {} : null,
                    onTapDown: isOnline
                        ? (_) {
                            unawaited(_startTalk());
                          }
                        : null,
                    onTapUp: isOnline
                        ? (_) {
                            unawaited(_stopTalk());
                          }
                        : null,
                    onTapCancel: isOnline
                        ? () {
                            unawaited(_stopTalk());
                          }
                        : null,
                  ),
                ),
            ],
          ),
        if (hasPrimaryControls && hasAdvancedControls)
          const SizedBox(height: 16),
        if (hasAdvancedControls)
          Card(
            child: Column(
              children: [
                if (capabilities.supportsPtz)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.control_camera_outlined),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Sterowanie kamerą',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        IconButton.filledTonal(
                          onPressed: isOnline
                              ? () {
                                  _nudgePtz(CameraPtzDirection.up);
                                }
                              : null,
                          icon: const Icon(Icons.keyboard_arrow_up),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton.filledTonal(
                              onPressed: isOnline
                                  ? () {
                                      _nudgePtz(CameraPtzDirection.left);
                                    }
                                  : null,
                              icon: const Icon(Icons.keyboard_arrow_left),
                            ),
                            const SizedBox(width: 38),
                            IconButton.filledTonal(
                              onPressed: isOnline
                                  ? () {
                                      _nudgePtz(CameraPtzDirection.right);
                                    }
                                  : null,
                              icon: const Icon(Icons.keyboard_arrow_right),
                            ),
                          ],
                        ),
                        IconButton.filledTonal(
                          onPressed: isOnline
                              ? () {
                                  _nudgePtz(CameraPtzDirection.down);
                                }
                              : null,
                          icon: const Icon(Icons.keyboard_arrow_down),
                        ),
                      ],
                    ),
                  ),
                if (capabilities.supportsPtz &&
                    (capabilities.supportsFloodlight ||
                        capabilities.supportsSiren))
                  const Divider(height: 1),
                if (capabilities.supportsFloodlight)
                  SwitchListTile(
                    secondary: const Icon(Icons.lightbulb_outline),
                    title: const Text('Reflektor'),
                    subtitle: Text(
                      _floodlightBusy
                          ? 'Zmieniam...'
                          : _floodlightEnabled
                          ? 'Włączony'
                          : 'Wyłączony',
                    ),
                    value: _floodlightEnabled,
                    onChanged: isOnline && !_floodlightBusy
                        ? _setFloodlight
                        : null,
                  ),
                if (capabilities.supportsFloodlight &&
                    capabilities.supportsSiren)
                  const Divider(height: 1),
                if (capabilities.supportsSiren)
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: const Text('Syrena'),
                    subtitle: Text(
                      _sirenBusy
                          ? 'Zmieniam...'
                          : _sirenEnabled
                          ? 'Włączona'
                          : 'Wyłączona',
                    ),
                    value: _sirenEnabled,
                    onChanged: isOnline && !_sirenBusy ? _setSiren : null,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;

  final VoidCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final VoidCallback? onTapCancel;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      onTapDown: onTapDown,
      onTapUp: onTapUp,
      onTapCancel: onTapCancel,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: active ? colorScheme.primaryContainer : null,
          border: Border.all(
            color: active ? colorScheme.primary : colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: onTap == null
                  ? colorScheme.onSurfaceVariant.withValues(alpha: 0.45)
                  : null,
            ),
            const SizedBox(height: 8),
            Text(label, maxLines: 2, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
