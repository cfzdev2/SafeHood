import 'dart:async';

import 'package:flutter/material.dart';

import 'package:video_player/video_player.dart';
import '../../incidents/data/incident_service.dart';
import '../data/camera_provider_factory.dart';
import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import '../../camera_events/presentation/camera_event_history_screen.dart';
import 'camera_settings_screen.dart';
import 'widgets/camera_controls_panel.dart';
import 'camera_recordings_screen.dart';
import 'camera_snapshot_preview_screen.dart';

class CameraDetailsScreen extends StatefulWidget {
  final Camera camera;

  const CameraDetailsScreen({super.key, required this.camera});

  @override
  State<CameraDetailsScreen> createState() => _CameraDetailsScreenState();
}

class _CameraDetailsScreenState extends State<CameraDetailsScreen> {
  late final CameraProvider _cameraProvider;
  late final Stream<CameraRuntimeState> _cameraStateStream;

  VideoPlayerController? _videoController;

  bool _liveLoading = true;
  Object? _liveError;
  bool _audioEnabled = true;
  bool _snapshotLoading = false;

  @override
  void initState() {
    super.initState();

    _cameraProvider = CameraProviderFactory.create(widget.camera);

    _cameraStateStream = _cameraProvider.watchState();

    unawaited(_initializeLive());
  }

  Future<void> _initializeLive() async {
    VideoPlayerController? nextController;

    try {
      await _cameraProvider.connect();

      final streamUri = _cameraProvider.liveStreamUri;

      if (streamUri == null) {
        throw StateError(
          'Kamera nie udostępniła '
          'strumienia LIVE.',
        );
      }

      await _cameraProvider.startLive();

      nextController = VideoPlayerController.networkUrl(streamUri);

      await nextController.initialize();
      await nextController.setLooping(false);
      await nextController.setVolume(_audioEnabled ? 1 : 0);
      await nextController.play();

      if (!mounted) {
        await nextController.dispose();
        return;
      }

      final previousController = _videoController;

      _videoController = nextController;

      setState(() {
        _liveError = null;
        _liveLoading = false;
      });

      if (previousController != null) {
        await previousController.dispose();
      }
    } catch (error) {
      await nextController?.dispose();

      debugPrint(
        'CAMERA LIVE ERROR '
        '[${widget.camera.id}]: $error',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _videoController = null;
        _liveError = error;
        _liveLoading = false;
      });
    }
  }

  Future<void> _retryLive() async {
    if (_liveLoading) {
      return;
    }

    final controller = _videoController;
    _videoController = null;

    setState(() {
      _liveLoading = true;
      _liveError = null;
    });

    if (controller != null) {
      try {
        await controller.dispose();
      } catch (error) {
        debugPrint('CAMERA LIVE DISPOSE ERROR: $error');
      }
    }

    try {
      await _cameraProvider.stopLive();
    } catch (error) {
      debugPrint('CAMERA LIVE STOP ERROR: $error');
    }

    if (!mounted) {
      return;
    }

    await _initializeLive();
  }

  Future<void> _toggleAudio() async {
    final controller = _videoController;

    if (controller == null || !controller.value.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Strumień LIVE nie jest '
            'jeszcze gotowy.',
          ),
        ),
      );

      return;
    }

    final nextValue = !_audioEnabled;

    try {
      await controller.setVolume(nextValue ? 1 : 0);

      if (!mounted) {
        return;
      }

      setState(() {
        _audioEnabled = nextValue;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się zmienić '
            'dźwięku: $error',
          ),
        ),
      );
    }
  }

  Future<void> _takeSnapshot() async {
    if (_snapshotLoading) {
      return;
    }

    setState(() {
      _snapshotLoading = true;
    });

    try {
      if (_cameraProvider is CameraSnapshotSource) {
        final source = _cameraProvider as CameraSnapshotSource;
        final snapshot = await source.captureSnapshot();

        if (!mounted) {
          return;
        }

        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => CameraSnapshotPreviewScreen(
              camera: widget.camera,
              snapshot: snapshot,
            ),
          ),
        );

        return;
      }

      await _cameraProvider.takeSnapshot();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Snapshot wykonany.')));
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nie udało się wykonać snapshotu: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _snapshotLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    final controller = _videoController;
    _videoController = null;

    if (controller != null) {
      unawaited(controller.dispose());
    }

    unawaited(_cameraProvider.stopLive());

    unawaited(_cameraProvider.disconnect());

    unawaited(_cameraProvider.dispose());

    super.dispose();
  }

  String _statusLabel(CameraRuntimeState state) {
    if (state.isConnecting) {
      return 'Łączenie...';
    }

    if (!state.isOnline) {
      return 'Offline';
    }

    if (state.isLive) {
      return 'LIVE';
    }

    return 'Gotowa';
  }

  Color _statusColor(CameraRuntimeState state) {
    if (state.isConnecting) {
      return Colors.orange;
    }

    if (!state.isOnline) {
      return Colors.red;
    }

    if (state.isLive) {
      return Colors.green;
    }

    return Colors.blue;
  }

  Future<void> _setMotionDetection(bool enabled) async {
    try {
      await _cameraProvider.setMotionDetection(enabled);
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się zmienić '
            'wykrywania ruchu: $error',
          ),
        ),
      );
    }
  }

  Future<void> _openCameraSettings() async {
    final cameraDeleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CameraSettingsScreen(camera: widget.camera),
      ),
    );

    if (cameraDeleted != true || !mounted) {
      return;
    }

    Navigator.of(context).pop();
  }

  Future<void> _reportProblem(BuildContext context) async {
    final result = await showDialog<_IncidentFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return const _ReportIncidentDialog();
      },
    );

    if (result == null || !context.mounted) {
      return;
    }

    try {
      await IncidentService().createIncident(
        cameraId: widget.camera.id,
        cameraName: widget.camera.name,
        title: result.title,
        description: result.description,
      );

      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zgłoszenie zostało utworzone.')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się utworzyć '
            'zgłoszenia: $error',
          ),
        ),
      );
    }
  }

  Widget _buildLivePreview() {
    if (_liveLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 12),
            Text(
              'Łączenie z kamerą...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    if (_liveError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_outlined,
                size: 56,
                color: Colors.white70,
              ),
              const SizedBox(height: 12),
              const Text(
                'Nie udało się połączyć '
                'ze strumieniem LIVE.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _retryLive,
                icon: const Icon(Icons.refresh),
                label: const Text('Połącz ponownie'),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _videoController;

    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: Icon(
          Icons.videocam_off_outlined,
          size: 56,
          color: Colors.white70,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }

  Future<void> _openRecordings() async {
    final CameraRecordingsSource? source =
        _cameraProvider is CameraRecordingsSource
        ? _cameraProvider as CameraRecordingsSource
        : null;

    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ta kamera nie udostępnia '
            'jeszcze nagrań.',
          ),
        ),
      );

      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) {
          return CameraRecordingsScreen(camera: widget.camera, source: source);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = _cameraProvider.capabilities;

    return StreamBuilder<CameraRuntimeState>(
      stream: _cameraStateStream,
      initialData: CameraRuntimeState.fromCamera(widget.camera),
      builder: (context, snapshot) {
        final state =
            snapshot.data ?? CameraRuntimeState.fromCamera(widget.camera);

        return Scaffold(
          appBar: AppBar(title: Text(widget.camera.name)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(child: _buildLivePreview()),

                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 9,
                                color: _statusColor(state),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _statusLabel(state),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              Text(
                widget.camera.name,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 4),

              Text(
                widget.camera.locationName,
                style: Theme.of(context).textTheme.bodyLarge,
              ),

              const SizedBox(height: 24),

              CameraControlsPanel(
                provider: _cameraProvider,
                state: state,
                audioEnabled: _audioEnabled,
                onToggleAudio: _toggleAudio,
              ),

              const SizedBox(height: 24),

              Card(
                child: Column(
                  children: [
                    if (capabilities.supportsMotionDetection)
                      SwitchListTile(
                        secondary: const Icon(Icons.directions_run),
                        title: const Text('Wykrywanie ruchu'),
                        subtitle: Text(
                          state.motionDetectionEnabled
                              ? 'Włączone'
                              : 'Wyłączone',
                        ),
                        value: state.motionDetectionEnabled,
                        onChanged: state.isOnline
                            ? (enabled) {
                                _setMotionDetection(enabled);
                              }
                            : null,
                      ),

                    if (capabilities.supportsRecordings)
                      const Divider(height: 1),

                    ListTile(
                      leading: const Icon(Icons.history),
                      title: const Text('Historia wykryć'),
                      subtitle: const Text(
                        'Ruch, osoby, pojazdy i inne zdarzenia',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) {
                              return CameraEventHistoryScreen(
                                cameraId: widget.camera.id,
                                cameraName: widget.camera.name,
                              );
                            },
                          ),
                        );
                      },
                    ),

                    const Divider(height: 1),

                    if (capabilities.supportsRecordings)
                      ListTile(
                        leading: const Icon(Icons.video_library_outlined),
                        title: const Text('Nagrania'),
                        subtitle: Text(
                          widget.camera.hasSdCard
                              ? 'Chmura i karta SD'
                              : 'Nagrania w chmurze',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: state.isOnline ? _openRecordings : null,
                      ),

                    const Divider(height: 1),

                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('Model'),
                      subtitle: Text(
                        '${widget.camera.brand} '
                        '${widget.camera.model}',
                      ),
                    ),
                    const Divider(height: 1),

                    ListTile(
                      leading: const Icon(Icons.router_outlined),
                      title: const Text('Typ połączenia'),
                      subtitle: Text(widget.camera.connectionType.name),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              FilledButton.icon(
                onPressed: () {
                  _reportProblem(context);
                },
                icon: const Icon(Icons.warning_amber),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('Zgłoś problem', style: TextStyle(fontSize: 16)),
                ),
              ),

              if (capabilities.supportsSnapshot) const SizedBox(height: 10),

              if (capabilities.supportsSnapshot)
                OutlinedButton.icon(
                  onPressed: state.isOnline && !_snapshotLoading
                      ? _takeSnapshot
                      : null,
                  icon: _snapshotLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt_outlined),
                  label: Text(
                    _snapshotLoading
                        ? 'Wykonywanie zdjęcia...'
                        : 'Zrób zdjęcie',
                  ),
                ),

              const SizedBox(height: 10),

              OutlinedButton.icon(
                onPressed: _openCameraSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Ustawienia kamery'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _IncidentFormResult {
  final String title;
  final String description;

  const _IncidentFormResult({required this.title, required this.description});
}

class _ReportIncidentDialog extends StatefulWidget {
  const _ReportIncidentDialog();

  @override
  State<_ReportIncidentDialog> createState() => _ReportIncidentDialogState();
}

class _ReportIncidentDialogState extends State<_ReportIncidentDialog> {
  static const List<String> incidentTypes = [
    'Podejrzana osoba',
    'Próba włamania',
    'Kradzież',
    'Podejrzany pojazd',
    'Nietypowa aktywność',
    'Inne',
  ];

  String selectedType = incidentTypes.first;

  String description = '';
  bool isClosing = false;

  Future<void> _closeDialog({_IncidentFormResult? result}) async {
    if (isClosing) {
      return;
    }

    setState(() {
      isClosing = true;
    });

    FocusManager.instance.primaryFocus?.unfocus();

    await Future<void>.delayed(const Duration(milliseconds: 100));

    if (!mounted) {
      return;
    }

    Navigator.of(context).pop(result);
  }

  void _submit() {
    _closeDialog(
      result: _IncidentFormResult(
        title: selectedType,
        description: description.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Zgłoś problem'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: selectedType,
              decoration: const InputDecoration(
                labelText: 'Rodzaj zdarzenia',
                border: OutlineInputBorder(),
              ),
              items: incidentTypes
                  .map(
                    (type) => DropdownMenuItem<String>(
                      value: type,
                      child: Text(type),
                    ),
                  )
                  .toList(),
              onChanged: isClosing
                  ? null
                  : (value) {
                      if (value == null) {
                        return;
                      }

                      setState(() {
                        selectedType = value;
                      });
                    },
            ),

            const SizedBox(height: 16),

            TextField(
              enabled: !isClosing,
              maxLines: 4,
              onChanged: (value) {
                description = value;
              },
              decoration: const InputDecoration(
                labelText: 'Opis (opcjonalnie)',
                hintText:
                    'Np. osoba chodzi przy '
                    'zaparkowanych samochodach...',
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 12),

            const Text(
              'Zgłoszenie będzie aktywne '
              'przez maksymalnie 60 minut.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: isClosing
              ? null
              : () {
                  _closeDialog();
                },
          child: const Text('Anuluj'),
        ),
        FilledButton.icon(
          onPressed: isClosing ? null : _submit,
          icon: isClosing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.warning_amber),
          label: const Text('Utwórz zgłoszenie'),
        ),
      ],
    );
  }
}
