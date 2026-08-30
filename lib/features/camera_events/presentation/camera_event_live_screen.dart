import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../cameras/data/camera_provider_factory.dart';
import '../../cameras/domain/camera.dart';
import '../../cameras/domain/camera_provider.dart';

class CameraEventLiveScreen extends StatefulWidget {
  final Camera camera;

  const CameraEventLiveScreen({super.key, required this.camera});

  @override
  State<CameraEventLiveScreen> createState() => _CameraEventLiveScreenState();
}

class _CameraEventLiveScreenState extends State<CameraEventLiveScreen> {
  late final CameraProvider _cameraProvider;

  VideoPlayerController? _videoController;

  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();

    _cameraProvider = CameraProviderFactory.create(widget.camera);

    unawaited(_initializeLive());
  }


  Future<void> _initializeLive() async {
    try {
      debugPrint(
        'LIVE: łączę z kamerą '
        '${widget.camera.id}',
      );

      await _cameraProvider.connect();

      final streamUri = _cameraProvider.liveStreamUri;

      if (streamUri == null) {
        throw StateError(
          'Kamera nie udostępniła '
          'strumienia LIVE.',
        );
      }

      debugPrint(
        'LIVE: stream URI = '
        '$streamUri',
      );

      await _cameraProvider.startLive();

      final controller = VideoPlayerController.networkUrl(streamUri);

      _videoController = controller;

      await controller.initialize();

      await controller.setLooping(false);

      await controller.play();

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('LIVE ERROR: $error');

      debugPrint(
        'LIVE STACKTRACE: '
        '$stackTrace',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _videoController;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _shutdown() async {
  final controller = _videoController;

    _videoController = null;

    if (controller != null) {
      try {
        await controller.pause();
      } catch (_) {}

      try {
        await controller.dispose();
      } catch (_) {}
    }

    try {
      await _cameraProvider.stopLive();
    } catch (_) {}

    try {
      await _cameraProvider.disconnect();
    } catch (_) {}

    try {
      await _cameraProvider.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_shutdown());

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.camera.name} • LIVE')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Łączenie z kamerą...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, size: 64),
              const SizedBox(height: 16),
              const Text(
                'Nie udało się '
                'uruchomić LIVE.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    final controller = _videoController!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 10, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.camera.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio > 0
                ? controller.value.aspectRatio
                : 16 / 9,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: Container(color: Colors.black)),
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
        const SizedBox(height: 12),
        Text(
          'Strumień na żywo '
          'z kamery.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
