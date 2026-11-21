import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../camera_events/data/camera_event_service.dart';
import '../domain/camera.dart';
import 'camera_live_playback.dart';
import 'camera_live_session.dart';
import 'camera_service.dart';
import 'live_motion_detector.dart';

enum LiveMotionStatus {
  off,
  waiting,
  watching,
  unavailable,
  saving,
  saved,
  saveFailed,
}

bool supportsLiveMotion(Camera camera) =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android &&
    camera.usesLocalConnection;

typedef LiveMotionFrame = Future<Uint8List?> Function(VideoPlayerController);
typedef SaveLiveMotion = Future<void> Function(DateTime, Uint8List?);

/// Shares the LIVE player and follows its lifecycle, including fullscreen.
class LiveMotionMonitor extends ValueNotifier<LiveMotionStatus> {
  LiveMotionMonitor({
    required this._session,
    required Stream<bool> enabled,
    required this._sample,
    required this._snapshot,
    required this._save,
  }) : super(LiveMotionStatus.off) {
    _session.addListener(_sync);
    _settings = enabled.listen(_enable, onError: (Object _) => _enable(false));
  }

  static LiveMotionMonitor? attach(Camera camera, CameraLiveSession session) {
    if (!supportsLiveMotion(camera)) return null;
    final events = CameraEventService();
    return LiveMotionMonitor(
      session: session,
      enabled: CameraService().watchLiveMotionEnabled(camera.id),
      sample: (player) => _readFrame(player, 'sample'),
      snapshot: (player) => _readFrame(player, 'snapshot'),
      save: (time, jpeg) async {
        await events.ingestFromCamera(
          cameraId: camera.id,
          type: 'motion',
          source: 'phone-motion',
          occurredAt: time,
          phoneSnapshot: jpeg,
        );
      },
    );
  }

  static const _channel = MethodChannel('safehood/camera_frame');
  static const _sampleInterval = Duration(milliseconds: 800);
  static const _sendInterval = Duration(seconds: 30);
  final CameraLiveSession _session;
  final LiveMotionFrame _sample;
  final LiveMotionFrame _snapshot;
  final SaveLiveMotion _save;
  final _detector = LiveMotionDetector();
  final _sinceLastEvent = Stopwatch();
  late final StreamSubscription<bool> _settings;
  VideoPlayerController? _player;
  Timer? _timer;
  int _generation = 0;
  int _misses = 0;
  bool _enabled = false;
  bool _closed = false;

  static Future<Uint8List?> _readFrame(
    VideoPlayerController player,
    String method,
  ) async {
    final session = CameraLivePlayback.frameSessionFor(player);
    final size = player.value.size;
    if (session == null || size.isEmpty || !size.isFinite) return null;
    final scale = math.min(1.0, 480.0 / math.max(size.width, size.height));
    return _channel.invokeMethod<Uint8List>(method, {
      'session': session,
      if (method == 'snapshot')
        'width': math.max(1, (size.width * scale).round()),
      if (method == 'snapshot')
        'height': math.max(1, (size.height * scale).round()),
    });
  }

  void _enable(bool enabled) {
    if (_closed || _enabled == enabled) return;
    _enabled = enabled;
    _sync();
  }

  void _sync() {
    final player = _enabled ? _session.controller : null;
    if (player == null || !identical(player, _player)) {
      _stopSampling();
      _player = player;
      value = _enabled ? LiveMotionStatus.waiting : LiveMotionStatus.off;
      if (player != null) _schedule(player, _generation);
    }
  }

  void _stopSampling() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _misses = 0;
    _detector.reset();
  }

  bool _current(VideoPlayerController player, int generation) =>
      !_closed && generation == _generation && identical(player, _player);

  bool _ready(VideoPlayerController player) {
    final playback = player.value;
    return playback.isInitialized &&
        playback.isPlaying &&
        !playback.isBuffering &&
        !playback.hasError;
  }

  void _schedule(VideoPlayerController player, int generation) {
    _timer = Timer(_sampleInterval, () => _tick(player, generation));
  }

  Future<void> _tick(VideoPlayerController player, int generation) async {
    bool current() => _current(player, generation);
    if (!current()) return;
    try {
      if (!_ready(player)) {
        _detector.reset();
        _misses = 0;
        value = LiveMotionStatus.waiting;
        return;
      }

      final frame = await _tryRead(_sample, player);
      if (!current() || !_ready(player)) return;
      if (frame == null || frame.length != LiveMotionDetector.pixels) {
        _detector.reset();
        if (++_misses >= 6) value = LiveMotionStatus.unavailable;
        return;
      }

      _misses = 0;
      if (value == LiveMotionStatus.waiting ||
          value == LiveMotionStatus.unavailable) {
        value = LiveMotionStatus.watching;
      }
      if (!_detector.add(frame) ||
          (_sinceLastEvent.isRunning &&
              _sinceLastEvent.elapsed < _sendInterval)) {
        return;
      }

      final occurredAt = DateTime.now();
      value = LiveMotionStatus.saving;
      final jpeg = await _tryRead(_snapshot, player);
      if (!current()) return;
      if (!_ready(player)) {
        value = LiveMotionStatus.waiting;
        return;
      }

      _sinceLastEvent
        ..reset()
        ..start();
      try {
        await _save(occurredAt, jpeg).timeout(const Duration(seconds: 20));
        if (current()) value = LiveMotionStatus.saved;
      } catch (error) {
        debugPrint('PHONE MOTION EVENT: ${error.runtimeType}');
        if (current()) value = LiveMotionStatus.saveFailed;
      }
    } finally {
      if (current()) _schedule(player, generation);
    }
  }

  Future<Uint8List?> _tryRead(
    LiveMotionFrame read,
    VideoPlayerController player,
  ) async {
    try {
      return await read(player).timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _session.removeListener(_sync);
    unawaited(_settings.cancel());
    _stopSampling();
    _player = null;
    super.dispose();
  }
}
