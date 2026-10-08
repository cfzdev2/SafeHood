import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../domain/camera_event.dart';
import '../camera_event_live_screen.dart';

class CameraEventClip extends StatefulWidget {
  final CameraEvent event;

  const CameraEventClip({super.key, required this.event});

  @override
  State<CameraEventClip> createState() => _CameraEventClipState();
}

class _CameraEventClipState extends State<CameraEventClip>
    with WidgetsBindingObserver {
  static const _maximumBytes = 6 * 1024 * 1024;

  VideoPlayerController? _controller;
  Directory? _directory;
  DownloadTask? _download;
  StreamSubscription<User?>? _authChanges;
  Route<void>? _fullscreenRoute;
  NavigatorState? _fullscreenNavigator;
  int _generation = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watchAuthentication();
    unawaited(_initialize());
  }

  void _watchAuthentication() {
    unawaited(_authChanges?.cancel());
    _authChanges = null;
    if (widget.event.clipPath?.trim().isNotEmpty ?? false) {
      final ownerId = widget.event.ownerId;
      _authChanges = FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user?.uid != ownerId &&
            widget.event.ownerId == ownerId &&
            mounted) {
          _generation++;
          unawaited(_release());
          setState(() {
            _loading = false;
            _error = 'Zaloguj się na konto właściciela nagrania.';
          });
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant CameraEventClip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.id != widget.event.id ||
        oldWidget.event.ownerId != widget.event.ownerId ||
        oldWidget.event.clipPath != widget.event.clipPath ||
        oldWidget.event.clipUrl != widget.event.clipUrl) {
      _watchAuthentication();
      unawaited(_initialize());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_controller?.pause());
    }
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _initialize() async {
    final generation = ++_generation;
    final event = widget.event;
    await _release();
    if (!_current(generation)) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    VideoPlayerController? controller;
    Directory? directory;
    DownloadTask? download;
    try {
      if (event.clipPath?.trim().isNotEmpty ?? false) {
        if (kIsWeb) {
          throw StateError(
            'Prywatne nagranie otworzysz w aplikacji na telefonie.',
          );
        }
        final privatePath = event.privateClipPath;
        if (privatePath == null ||
            FirebaseAuth.instance.currentUser?.uid != event.ownerId) {
          throw StateError('Nagranie jest dostępne tylko dla właściciela.');
        }
        final reference = FirebaseStorage.instance.ref(privatePath);
        final metadata = await reference.getMetadata().timeout(
          const Duration(seconds: 20),
        );
        if (!_current(generation)) {
          return;
        }
        if (metadata.contentType != 'video/mp4' ||
            metadata.size == null ||
            metadata.size! < 100 ||
            metadata.size! > _maximumBytes) {
          throw StateError('Nagranie ma nieprawidłowy rozmiar lub format.');
        }
        directory = await Directory.systemTemp.createTemp(
          'safehood-event-clip-',
        );
        if (!_current(generation)) {
          return;
        }
        _directory = directory;
        final file = File('${directory.path}${Platform.pathSeparator}clip.mp4');
        download = reference.writeToFile(file);
        _download = download;
        await download.timeout(const Duration(seconds: 60));
        if (!_current(generation)) {
          return;
        }
        if (FirebaseAuth.instance.currentUser?.uid != event.ownerId ||
            await file.length() > _maximumBytes) {
          throw StateError('Nagranie jest niedostępne.');
        }
        controller = VideoPlayerController.file(file);
      } else {
        final url = Uri.tryParse(event.clipUrl?.trim() ?? '');
        if (url == null ||
            !['https', 'http'].contains(url.scheme) ||
            url.host.isEmpty) {
          throw StateError('Brak nagrania.');
        }
        controller = VideoPlayerController.networkUrl(url);
      }
      await controller.initialize().timeout(const Duration(seconds: 20));
      await controller.setLooping(false);
      if (!_current(generation)) {
        return;
      }
      _controller = controller;
      controller.addListener(_updated);
      setState(() => _loading = false);
      controller = null;
      directory = null;
      download = null;
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _loading = false;
          _error = error is StateError
              ? error.message.toString()
              : 'Nie udało się pobrać nagrania. Spróbuj ponownie.';
        });
      }
    } finally {
      if (controller != null) {
        await controller.dispose().catchError((_) {});
      }
      if (download != null) {
        await download.cancel().catchError((_) => false);
      }
      final temporaryDirectory = directory;
      if (temporaryDirectory != null) {
        await temporaryDirectory
            .delete(recursive: true)
            .catchError((_) => temporaryDirectory);
        if (identical(_directory, temporaryDirectory)) {
          _directory = null;
        }
      }
    }
  }

  void _updated() {
    if (!mounted) {
      return;
    }
    setState(() {
      if (_controller?.value.hasError ?? false) {
        _error = 'Nie udało się odtworzyć nagrania. Spróbuj ponownie.';
      }
    });
  }

  Future<void> _release() async {
    final controller = _controller;
    final directory = _directory;
    final download = _download;
    final fullscreen = _fullscreenRoute;
    final navigator = _fullscreenNavigator;
    _fullscreenRoute = null;
    _fullscreenNavigator = null;
    if (fullscreen != null && navigator != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && fullscreen.isActive) {
          navigator.removeRoute(fullscreen);
        }
      });
    }
    _controller = null;
    _directory = null;
    _download = null;
    if (download != null) {
      await download.cancel().catchError((_) => false);
    }
    if (controller != null) {
      controller.removeListener(_updated);
      await controller.dispose().catchError((_) {});
    }
    if (directory != null) {
      await directory.delete(recursive: true).catchError((_) => directory);
    }
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
  }

  Future<void> _openFullscreen(VideoPlayerController controller) async {
    if (!mounted ||
        _fullscreenRoute != null ||
        !identical(_controller, controller)) {
      return;
    }
    final navigator = Navigator.of(context);
    final route = MaterialPageRoute<void>(
      builder: (_) => CameraFullscreenLiveView(controller: controller),
    );
    _fullscreenNavigator = navigator;
    _fullscreenRoute = route;
    await navigator.push<void>(route);
    if (identical(_fullscreenRoute, route)) {
      _fullscreenRoute = null;
      _fullscreenNavigator = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_authChanges?.cancel());
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 210,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Column(
        children: [
          const Icon(Icons.movie_outlined),
          const SizedBox(height: 8),
          Text(_error!, textAlign: TextAlign.center),
          TextButton(
            onPressed: () => unawaited(_initialize()),
            child: const Text('Spróbuj ponownie'),
          ),
        ],
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final prebuffer = widget.event.clipPrebufferMillis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Nagranie zdarzenia',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (prebuffer != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${(prebuffer / 1000).toStringAsFixed(1)} s przed wykryciem',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio > 0
                ? controller.value.aspectRatio
                : 16 / 9,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(controller),
                IconButton.filledTonal(
                  onPressed: () => unawaited(_togglePlayback()),
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.fullscreen),
                    onPressed: () => unawaited(_openFullscreen(controller)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        VideoProgressIndicator(controller, allowScrubbing: true),
      ],
    );
  }
}
