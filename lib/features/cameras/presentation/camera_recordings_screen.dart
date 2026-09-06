import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import '../domain/camera_recording.dart';

class CameraRecordingsScreen extends StatefulWidget {
  final Camera camera;
  final CameraRecordingsSource source;

  const CameraRecordingsScreen({
    super.key,
    required this.camera,
    required this.source,
  });

  @override
  State<CameraRecordingsScreen> createState() => _CameraRecordingsScreenState();
}

class _CameraRecordingsScreenState extends State<CameraRecordingsScreen> {
  final List<CameraRecording> _recordings = [];

  bool _loading = true;
  bool _loadingMore = false;

  Object? _error;
  String? _nextPageToken;
  String? _openingRecordingId;

  @override
  void initState() {
    super.initState();

    unawaited(_loadRecordings(reset: true));
  }

  Future<void> _loadRecordings({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      if (_loadingMore || _nextPageToken == null) {
        return;
      }

      setState(() {
        _loadingMore = true;
      });
    }

    try {
      final page = await widget.source.loadRecordings(
        pageToken: reset ? null : _nextPageToken,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        if (reset) {
          _recordings
            ..clear()
            ..addAll(page.recordings);
        } else {
          _recordings.addAll(page.recordings);
        }

        _nextPageToken = page.nextPageToken;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error;
      });
    }
  }

  Future<void> _openRecording(CameraRecording recording) async {
    if (_openingRecordingId != null) {
      return;
    }

    setState(() {
      _openingRecordingId = recording.id;
    });

    try {
      final playbackUri = await widget.source.getRecordingPlaybackUri(
        recording,
      );

      if (!mounted) {
        return;
      }

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) {
            return _CameraRecordingPlayerScreen(
              recording: recording,
              playbackUri: playbackUri,
            );
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
            'nagrania: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _openingRecordingId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Nagrania • '
          '${widget.camera.name}',
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _recordings.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _recordings.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 52),
              const SizedBox(height: 16),
              const Text(
                'Nie udało się pobrać '
                'nagrań.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  _loadRecordings(reset: true);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Spróbuj ponownie'),
              ),
            ],
          ),
        ),
      );
    }

    if (_recordings.isEmpty) {
      return RefreshIndicator(
        onRefresh: () {
          return _loadRecordings(reset: true);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 150),
            Icon(Icons.video_library_outlined, size: 56),
            SizedBox(height: 16),
            Center(child: Text('Brak nagrań.')),
          ],
        ),
      );
    }

    final hasMore = _nextPageToken != null;

    return RefreshIndicator(
      onRefresh: () {
        return _loadRecordings(reset: true);
      },
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _recordings.length + (hasMore ? 1 : 0),
        separatorBuilder: (_, _) {
          return const SizedBox(height: 12);
        },
        itemBuilder: (context, index) {
          if (index == _recordings.length) {
            return Center(
              child: _loadingMore
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    )
                  : OutlinedButton.icon(
                      onPressed: () {
                        _loadRecordings(reset: false);
                      },
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Wczytaj więcej'),
                    ),
            );
          }

          final recording = _recordings[index];

          final opening = _openingRecordingId == recording.id;

          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: opening
                  ? null
                  : () {
                      _openRecording(recording);
                    },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _RecordingThumbnail(recording: recording),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _triggerLabel(recording.trigger),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(_formatDateTime(recording.startedAt)),
                          const SizedBox(height: 4),
                          Text(
                            '${_storageLabel(recording.storage)}'
                            ' • '
                            '${_formatDuration(recording.duration)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (opening)
                      const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.play_circle_outline, size: 32),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _triggerLabel(CameraRecordingTrigger trigger) {
    switch (trigger) {
      case CameraRecordingTrigger.motion:
        return 'Wykryto ruch';

      case CameraRecordingTrigger.person:
        return 'Wykryto osobę';

      case CameraRecordingTrigger.vehicle:
        return 'Wykryto pojazd';

      case CameraRecordingTrigger.sound:
        return 'Wykryto dźwięk';

      case CameraRecordingTrigger.manual:
        return 'Nagranie ręczne';

      case CameraRecordingTrigger.continuous:
        return 'Nagranie ciągłe';

      case CameraRecordingTrigger.unknown:
        return 'Nagranie';
    }
  }

  String _storageLabel(CameraRecordingStorage storage) {
    switch (storage) {
      case CameraRecordingStorage.cloud:
        return 'Chmura';

      case CameraRecordingStorage.sdCard:
        return 'Karta SD';

      case CameraRecordingStorage.unknown:
        return 'Nieznane źródło';
    }
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();

    final day = local.day.toString().padLeft(2, '0');

    final month = local.month.toString().padLeft(2, '0');

    final hour = local.hour.toString().padLeft(2, '0');

    final minute = local.minute.toString().padLeft(2, '0');

    return '$day.$month.${local.year}, '
        '$hour:$minute';
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;

    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');

    return '$minutes:$seconds';
  }
}

class _RecordingThumbnail extends StatelessWidget {
  final CameraRecording recording;

  const _RecordingThumbnail({required this.recording});

  @override
  Widget build(BuildContext context) {
    final thumbnailUri = recording.thumbnailUri;

    return SizedBox(
      width: 100,
      height: 64,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: thumbnailUri == null
            ? _placeholder()
            : Image.network(
                thumbnailUri.toString(),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return _placeholder();
                },
              ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: Colors.black87,
      child: const Center(
        child: Icon(Icons.videocam_outlined, color: Colors.white70),
      ),
    );
  }
}

class _CameraRecordingPlayerScreen extends StatefulWidget {
  final CameraRecording recording;
  final Uri playbackUri;

  const _CameraRecordingPlayerScreen({
    required this.recording,
    required this.playbackUri,
  });

  @override
  State<_CameraRecordingPlayerScreen> createState() =>
      _CameraRecordingPlayerScreenState();
}

class _CameraRecordingPlayerScreenState
    extends State<_CameraRecordingPlayerScreen> {
  VideoPlayerController? _controller;

  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();

    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final controller = VideoPlayerController.networkUrl(widget.playbackUri);

    _controller = controller;

    try {
      await controller.initialize();

      await controller.setLooping(false);
      await controller.play();

      controller.addListener(_handleVideoChanged);

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

  void _handleVideoChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    final controller = _controller;

    if (controller != null) {
      controller.removeListener(_handleVideoChanged);

      unawaited(controller.dispose());
    }

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
    return Scaffold(
      appBar: AppBar(title: const Text('Odtwarzanie nagrania')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nie udało się odtworzyć '
            'nagrania.\n\n$_error',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: Text('Nagranie jest niedostępne.'));
    }

    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AspectRatio(
          aspectRatio: aspectRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: VideoPlayer(controller)),
                IconButton.filled(
                  onPressed: _togglePlayback,
                  iconSize: 42,
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
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
        const SizedBox(height: 20),
        Text(
          _recordingTitle(widget.recording.trigger),
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Źródło: '
          '${_recordingStorage(widget.recording.storage)}',
        ),
      ],
    );
  }

  String _recordingTitle(CameraRecordingTrigger trigger) {
    switch (trigger) {
      case CameraRecordingTrigger.person:
        return 'Wykrycie osoby';

      case CameraRecordingTrigger.vehicle:
        return 'Wykrycie pojazdu';

      case CameraRecordingTrigger.motion:
        return 'Wykrycie ruchu';

      case CameraRecordingTrigger.sound:
        return 'Wykrycie dźwięku';

      case CameraRecordingTrigger.manual:
        return 'Nagranie ręczne';

      case CameraRecordingTrigger.continuous:
        return 'Nagranie ciągłe';

      case CameraRecordingTrigger.unknown:
        return 'Nagranie';
    }
  }

  String _recordingStorage(CameraRecordingStorage storage) {
    switch (storage) {
      case CameraRecordingStorage.cloud:
        return 'chmura';

      case CameraRecordingStorage.sdCard:
        return 'karta SD';

      case CameraRecordingStorage.unknown:
        return 'nieznane';
    }
  }
}
