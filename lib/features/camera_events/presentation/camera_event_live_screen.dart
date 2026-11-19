import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../cameras/data/camera_provider_factory.dart';
import '../../cameras/data/camera_live_session.dart';
import '../../cameras/domain/camera.dart';
import '../../cameras/presentation/widgets/camera_live_placeholder.dart';
import 'package:flutter/services.dart';

class CameraEventLiveScreen extends StatefulWidget {
  final Camera camera;

  const CameraEventLiveScreen({super.key, required this.camera});

  @override
  State<CameraEventLiveScreen> createState() => _CameraEventLiveScreenState();
}

class _CameraEventLiveScreenState extends State<CameraEventLiveScreen>
    with WidgetsBindingObserver {
  late final CameraLiveSession _session;

  @override
  void initState() {
    super.initState();
    _session = CameraLiveSession(CameraProviderFactory.create(widget.camera));
    WidgetsBinding.instance.addObserver(this);
    _syncLiveActivity(WidgetsBinding.instance.lifecycleState);
  }

  void _syncLiveActivity(AppLifecycleState? state) {
    if (state == null || state == AppLifecycleState.resumed) {
      unawaited(_session.resume());
    } else {
      unawaited(_session.suspend());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncLiveActivity(state);
  }

  Future<void> _openFullscreen() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CameraFullscreenLiveView.live(session: _session),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.camera.name} • LIVE')),
      body: SafeArea(
        child: ListenableBuilder(listenable: _session, builder: _buildBody),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Widget? child) {
    final controller = _session.controller;
    if (controller == null) return CameraLivePlaceholder(session: _session);

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
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    onPressed: _openFullscreen,
                    tooltip: 'Pełny ekran',
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black54,
                    ),
                    icon: const Icon(Icons.fullscreen),
                  ),
                ),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, child) => IconButton(
                    onPressed: _session.togglePlayback,
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black54,
                    ),
                    iconSize: 38,
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
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

class CameraFullscreenLiveView extends StatefulWidget {
  final VideoPlayerController? _controller;
  final CameraLiveSession? _session;

  const CameraFullscreenLiveView({
    super.key,
    required VideoPlayerController this._controller,
  }) : _session = null;

  const CameraFullscreenLiveView.live({
    super.key,
    required CameraLiveSession this._session,
  }) : _controller = null;

  @override
  State<CameraFullscreenLiveView> createState() {
    return _CameraFullscreenLiveViewState();
  }
}

class _CameraFullscreenLiveViewState extends State<CameraFullscreenLiveView> {
  late final Future<void> _enterFullscreenFuture;

  bool _systemUiRestored = false;

  @override
  void initState() {
    super.initState();

    _enterFullscreenFuture = _enterFullscreen();
  }

  Future<void> _enterFullscreen() async {
    try {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);

      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (error) {
      debugPrint(
        'LIVE FULLSCREEN ENTER ERROR: '
        '${error.runtimeType}',
      );
    }
  }

  Future<void> _restoreSystemUi() async {
    if (_systemUiRestored) {
      return;
    }

    _systemUiRestored = true;

    await _enterFullscreenFuture;

    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    } catch (error) {
      debugPrint(
        'LIVE FULLSCREEN RESTORE ERROR: '
        '${error.runtimeType}',
      );
    }
  }

  Future<void> _closeFullscreen() async {
    await _restoreSystemUi();

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _togglePlayback(VideoPlayerController controller) async {
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  @override
  void dispose() {
    unawaited(_restoreSystemUi());

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget._session;
    if (session == null) return _buildScreen(widget._controller!);
    return ListenableBuilder(
      listenable: session,
      builder: (_, _) => _buildScreen(session.controller),
    );
  }

  Widget _buildScreen(VideoPlayerController? controller) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          if (controller == null)
            SafeArea(
              child: CameraLivePlaceholder(
                session: widget._session!,
                color: Colors.white70,
              ),
            )
          else
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio > 0
                    ? controller.value.aspectRatio
                    : 16 / 9,
                child: VideoPlayer(controller),
              ),
            ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                onPressed: _closeFullscreen,
                tooltip: 'Wyjdź z pełnego ekranu',
                style: IconButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.black54,
                ),
                icon: const Icon(Icons.fullscreen_exit),
              ),
            ),
          ),
          if (controller != null)
            Center(
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, child) {
                  return IconButton(
                    onPressed:
                        widget._session?.togglePlayback ??
                        () => _togglePlayback(controller),
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black54,
                    ),
                    iconSize: 42,
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
