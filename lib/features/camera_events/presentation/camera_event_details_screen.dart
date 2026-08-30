import 'package:flutter/material.dart';

import '../data/camera_event_service.dart';
import '../domain/camera_event.dart';
import 'package:video_player/video_player.dart';
import '../../cameras/data/camera_service.dart';
import 'camera_event_live_screen.dart';
import 'dart:async';

class CameraEventDetailsScreen extends StatefulWidget {
  final String eventId;

  const CameraEventDetailsScreen({super.key, required this.eventId});

  @override
  State<CameraEventDetailsScreen> createState() =>
      _CameraEventDetailsScreenState();
}

class _CameraEventDetailsScreenState extends State<CameraEventDetailsScreen> {
  final CameraEventService _eventService = CameraEventService();

  final CameraService _cameraService = CameraService();

  bool _markViewedRequested = false;
  bool _processingAction = false;

  bool _openingLive = false;

  Timer? _reactionExpiryTimer;
  DateTime? _scheduledReactionExpiry;

  static const List<String> _incidentTypes = [
    'Podejrzana osoba',
    'Próba włamania',
    'Kradzież',
    'Podejrzany pojazd',
    'Nietypowa aktywność',
    'Inne',
  ];

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
        return 'Wykryto manipulację kamerą';

      case CameraEventType.cameraOffline:
        return 'Kamera jest offline';

      case CameraEventType.cameraOnline:
        return 'Kamera jest online';

      case CameraEventType.unknown:
        return 'Wykryto aktywność';
    }
  }

  @override
  void dispose() {
    _reactionExpiryTimer?.cancel();
    super.dispose();
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
        return Icons.notifications_active_outlined;
    }
  }

  String _formatTime(DateTime dateTime) {
    final local = dateTime.toLocal();

    final hour = local.hour.toString().padLeft(2, '0');

    final minute = local.minute.toString().padLeft(2, '0');

    final second = local.second.toString().padLeft(2, '0');

    return '$hour:$minute:$second';
  }

  Future<void> _openLive(CameraEvent event) async {
    if (_openingLive) {
      return;
    }

    setState(() {
      _openingLive = true;
    });

    try {
      final camera = await _cameraService.getCamera(event.cameraId);

      if (camera == null) {
        throw StateError(
          'Nie znaleziono kamery '
          'powiązanej z wykryciem.',
        );
      }

      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) {
            return CameraEventLiveScreen(camera: camera);
          },
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się otworzyć '
            'LIVE: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _openingLive = false;
        });
      }
    }
  }

  Future<void> _markViewed(CameraEvent event) async {
    if (_markViewedRequested || !event.isNew) {
      return;
    }

    _markViewedRequested = true;

    try {
      await _eventService.markViewed(event.id);
    } catch (error) {
      debugPrint(
        'CAMERA EVENT MARK VIEWED ERROR: '
        '$error',
      );

      _markViewedRequested = false;
    }
  }

  Future<void> _dismiss(CameraEvent event) async {
    if (_processingAction) {
      return;
    }

    setState(() {
      _processingAction = true;
    });

    try {
      await _eventService.dismiss(event.id);

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Wykrycie oznaczono '
            'jako niegroźne.',
          ),
        ),
      );

      setState(() {
        _processingAction = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _processingAction = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się odrzucić '
            'wykrycia: $error',
          ),
        ),
      );
    }
  }

  Future<void> _reportProblem(CameraEvent event) async {
    if (_processingAction) {
      return;
    }

    final result = await showDialog<_IncidentFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return const _ReportIncidentDialog();
      },
    );

    if (result == null || !mounted) {
      return;
    }

    setState(() {
      _processingAction = true;
    });

    try {
      debugPrint(
        'CAMERA EVENT ESCALATE: '
        '${event.id}',
      );

      final escalationResult = await _eventService.escalate(
        eventId: event.id,
        title: result.title,
        description: result.description,
      );

      debugPrint(
        'CAMERA EVENT ESCALATED: '
        '${escalationResult.incidentId}',
      );

      if (!mounted) {
        return;
      }

      final message = escalationResult.alreadyEscalated
          ? 'To wykrycie było już '
                'powiązane ze zgłoszeniem.'
          : 'Zgłoszenie zostało '
                'utworzone i wysłane '
                'do osób w pobliżu.';

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

      setState(() {
        _processingAction = false;
      });
    } catch (error, stackTrace) {
      debugPrint(
        'CAMERA EVENT ESCALATE ERROR: '
        '$error',
      );

      debugPrint(
        'CAMERA EVENT ESCALATE STACKTRACE: '
        '$stackTrace',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _processingAction = false;
      });

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

  bool _isReactionExpired(CameraEvent event) {
    final expiresAt = event.lastOccurredAt.add(const Duration(hours: 1));

    return !DateTime.now().isBefore(expiresAt);
  }

  void _scheduleReactionExpiry(CameraEvent event) {
    if (event.isDismissed || event.isEscalated) {
      _reactionExpiryTimer?.cancel();
      _scheduledReactionExpiry = null;
      return;
    }

    final expiresAt = event.lastOccurredAt.add(const Duration(hours: 1));

    if (_scheduledReactionExpiry == expiresAt) {
      return;
    }

    _reactionExpiryTimer?.cancel();
    _scheduledReactionExpiry = expiresAt;

    final delay = expiresAt.difference(DateTime.now());

    if (delay <= Duration.zero) {
      return;
    }

    _reactionExpiryTimer = Timer(delay, () {
      if (!mounted) {
        return;
      }

      setState(() {});
    });
  }

  Widget _buildReactionSection(CameraEvent event) {
    if (event.isDismissed) {
      return _buildEventStatusCard(
        icon: Icons.check_circle_outline,
        title: 'Zdarzenie archiwalne',
        description: 'Oznaczono jako niegroźne.',
      );
    }

    if (event.isEscalated) {
      return _buildEventStatusCard(
        icon: Icons.warning_amber_outlined,
        title: 'Zdarzenie zgłoszone',
        description:
            'Problem został zgłoszony '
            'do osób w pobliżu.',
      );
    }

    if (_isReactionExpired(event)) {
      return _buildEventStatusCard(
        icon: Icons.history_outlined,
        title: 'Zdarzenie archiwalne',
        description:
            'Minął czas na reakcję '
            'na to wykrycie.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _processingAction
              ? null
              : () {
                  _dismiss(event);
                },
          icon: const Icon(Icons.check_circle_outline),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('To nic groźnego'),
          ),
        ),

        const SizedBox(height: 10),

        FilledButton.icon(
          onPressed: _processingAction
              ? null
              : () {
                  _reportProblem(event);
                },
          icon: _processingAction
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.warning_amber),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('Zgłoś problem'),
          ),
        ),
      ],
    );
  }

  Widget _buildEventStatusCard({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 4),

                Text(description),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wykrycie kamery')),
      body: StreamBuilder<CameraEvent?>(
        stream: _eventService.watchEvent(widget.eventId),
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
                  'wykrycia.\n\n'
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final event = snapshot.data;

          if (event == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nie znaleziono tego '
                  'wykrycia.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          _scheduleReactionExpiry(event);

          if (event.isNew) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _markViewed(event);
            });
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Icon(_eventIcon(event.type), size: 64),
                    const SizedBox(height: 16),
                    Text(
                      _eventTitle(event.type),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Godzina: '
                      '${_formatTime(event.lastOccurredAt)}',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      event.occurrenceCount == 1
                          ? '1 wykrycie'
                          : '${event.occurrenceCount} '
                                'wykrycia',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              if (event.hasSnapshot)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(event.snapshotUrl!, fit: BoxFit.cover),
                  ),
                )
              else
                Container(
                  height: 210,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.videocam_outlined,
                          size: 52,
                          color: Colors.white70,
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Podgląd zdarzenia '
                          'będzie dostępny tutaj',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),

              if (event.clipUrl != null &&
                  event.clipUrl!.trim().isNotEmpty) ...[
                const SizedBox(height: 16),

                _CameraEventClipPlayer(url: event.clipUrl!),
              ],

              const SizedBox(height: 16),

              OutlinedButton.icon(
                onPressed:
                    _openingLive || event.type == CameraEventType.cameraOffline
                    ? null
                    : () {
                        _openLive(event);
                      },
                icon: _openingLive
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.videocam_outlined),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    _openingLive
                        ? 'Łączenie z kamerą...'
                        : 'Otwórz podgląd LIVE',
                  ),
                ),
              ),

              const SizedBox(height: 24),

              _buildReactionSection(event),
            ],
          );
        },
      ),
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
  String _selectedType = _CameraEventDetailsScreenState._incidentTypes.first;

  final TextEditingController _descriptionController = TextEditingController();

  bool _closing = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  void _cancel() {
    if (_closing) {
      return;
    }

    setState(() {
      _closing = true;
    });

    Navigator.of(context).pop();
  }

  void _submit() {
    if (_closing) {
      return;
    }

    setState(() {
      _closing = true;
    });

    Navigator.of(context).pop(
      _IncidentFormResult(
        title: _selectedType,
        description: _descriptionController.text.trim(),
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
              initialValue: _selectedType,
              decoration: const InputDecoration(
                labelText: 'Rodzaj zdarzenia',
                border: OutlineInputBorder(),
              ),
              items: _CameraEventDetailsScreenState._incidentTypes.map((type) {
                return DropdownMenuItem<String>(value: type, child: Text(type));
              }).toList(),
              onChanged: _closing
                  ? null
                  : (value) {
                      if (value == null) {
                        return;
                      }

                      setState(() {
                        _selectedType = value;
                      });
                    },
            ),

            const SizedBox(height: 16),

            TextField(
              controller: _descriptionController,
              enabled: !_closing,
              maxLength: 500,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Opis (opcjonalnie)',
                hintText:
                    'Napisz krótko, '
                    'co się dzieje...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _closing ? null : _cancel,
          child: const Text('Anuluj'),
        ),
        FilledButton(
          onPressed: _closing ? null : _submit,
          child: const Text('Zgłoś'),
        ),
      ],
    );
  }
}

class _CameraEventClipPlayer extends StatefulWidget {
  final String url;

  const _CameraEventClipPlayer({required this.url});

  @override
  State<_CameraEventClipPlayer> createState() => _CameraEventClipPlayerState();
}

class _CameraEventClipPlayerState extends State<_CameraEventClipPlayer> {
  VideoPlayerController? _controller;

  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();

    _initialize();
  }

  Future<void> _initialize() async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));

    _controller = controller;

    try {
      await controller.initialize();

      await controller.setLooping(false);

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();

    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (controller.value.position >= controller.value.duration) {
        await controller.seekTo(Duration.zero);
      }

      await controller.play();
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: 210,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(height: 8),
            const Text(
              'Nie udało się '
              'załadować nagrania.',
            ),
            const SizedBox(height: 6),
            Text(
              '$_error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    final controller = _controller!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Nagranie zdarzenia',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),

        const SizedBox(height: 10),

        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(controller),

                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _togglePlayback,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        controller.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        VideoProgressIndicator(
          controller,
          allowScrubbing: true,
          padding: const EdgeInsets.only(top: 8),
        ),
      ],
    );
  }
}
