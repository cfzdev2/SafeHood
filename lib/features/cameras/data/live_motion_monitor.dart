import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_functions/cloud_functions.dart';
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
typedef SaveLiveMotion = Future<String?> Function(DateTime, Uint8List?);
typedef AttachLiveMotionClip = Future<void> Function(String, Uint8List);

/// Shares the LIVE player and follows its lifecycle, including fullscreen.
class LiveMotionMonitor extends ValueNotifier<LiveMotionStatus> {
  LiveMotionMonitor({
    required this._session,
    required Stream<bool> enabled,
    required this._sample,
    required this._snapshot,
    required this._save,
    this._recordClip,
    this._saveClip,
  }) : super(LiveMotionStatus.off) {
    _session.addListener(_sync);
    _settings = enabled.listen(_enable, onError: (Object _) => _enable(false));
  }

  static LiveMotionMonitor? attach(
    Camera camera,
    CameraLiveSession session, {
    bool recordClips = true,
  }) {
    if (!supportsLiveMotion(camera)) return null;
    final events = CameraEventService();
    return LiveMotionMonitor(
      session: session,
      enabled: CameraService().watchLiveMotionEnabled(camera.id),
      sample: (player) => _readFrame(player, 'sample'),
      snapshot: (player) => _readFrame(player, 'snapshot'),
      recordClip: recordClips ? (player) => _readFrame(player, 'clip') : null,
      save: (time, jpeg) async {
        final event = await events.ingestFromCamera(
          cameraId: camera.id,
          type: 'motion',
          source: 'phone-motion',
          occurredAt: time,
          phoneSnapshot: jpeg,
        );
        return event.eventId;
      },
      saveClip: (eventId, mp4) => events.attachPhoneMotionClip(
        cameraId: camera.id,
        eventId: eventId,
        mp4: mp4,
      ),
    );
  }

  static const _channel = MethodChannel('safehood/camera_frame');
  static const _sampleInterval = Duration(milliseconds: 800);
  static const _sendInterval = Duration(seconds: 30);
  final CameraLiveSession _session;
  final LiveMotionFrame _sample;
  final LiveMotionFrame _snapshot;
  final SaveLiveMotion _save;
  final LiveMotionFrame? _recordClip;
  final AttachLiveMotionClip? _saveClip;
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
    final clip = method == 'clip';
    final maxEdge = clip ? 320.0 : 480.0;
    final scale = math.min(1.0, maxEdge / math.max(size.width, size.height));
    int dimension(double value) => clip
        ? math.max(16, 16 * (value * scale / 16).floor())
        : math.max(1, (value * scale).round());
    return _channel.invokeMethod<Uint8List>(method, {
      'session': session,
      if (method != 'sample') 'width': dimension(size.width),
      if (method != 'sample') 'height': dimension(size.height),
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
      // A visual-only detection is untrusted if its frame cannot be read or
      // the native sampler rejected a corrupt image. Don't publish an alarm.
      if (!_ready(player) || jpeg == null) {
        _detector.reset();
        value = LiveMotionStatus.waiting;
        return;
      }

      _sinceLastEvent
        ..reset()
        ..start();
      final recording = _captureClip(player, generation);
      String? eventId;
      try {
        eventId = await _save(
          occurredAt,
          jpeg,
        ).timeout(const Duration(seconds: 20));
        if (current()) value = LiveMotionStatus.saved;
      } catch (error) {
        debugPrint('PHONE MOTION EVENT: ${error.runtimeType}');
        if (current()) value = LiveMotionStatus.saveFailed;
      }
      final clip = await recording;
      if (eventId != null && clip != null) {
        unawaited(_attachClip(eventId, clip));
      }
    } finally {
      if (current()) _schedule(player, generation);
    }
  }

  Future<Uint8List?> _captureClip(
    VideoPlayerController player,
    int generation,
  ) async {
    final record = _recordClip;
    if (record == null || _saveClip == null) return null;
    try {
      final bytes = await record(player).timeout(const Duration(seconds: 9));
      if (!_current(player, generation)) return null;
      if (bytes != null && bytes.length >= 100 && bytes.length <= 1024 * 1024) {
        return bytes;
      }
      debugPrint('PHONE MOTION RECORDING: clip unavailable');
    } catch (error) {
      debugPrint('PHONE MOTION RECORDING: ${error.runtimeType}');
    }
    return null;
  }

  Future<void> _attachClip(String eventId, Uint8List mp4) async {
    try {
      await _saveClip?.call(eventId, mp4);
    } on FirebaseFunctionsException catch (error) {
      debugPrint('PHONE MOTION CLIP UPLOAD: ${error.code}');
    } catch (error) {
      debugPrint('PHONE MOTION CLIP UPLOAD: ${error.runtimeType}');
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
