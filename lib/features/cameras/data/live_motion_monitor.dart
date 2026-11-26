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
typedef RecordLiveMotionClip =
    Future<LiveMotionClip?> Function(VideoPlayerController, LiveMotionAnchor?);
typedef AttachLiveMotionClip = Future<void> Function(String, LiveMotionClip);

class LiveMotionAnchor {
  const LiveMotionAnchor(this.timeUs, this.epoch);
  final int timeUs;
  final int epoch;
}

class LiveMotionSample {
  const LiveMotionSample(this.pixels, {this.anchor});
  final Uint8List pixels;
  final LiveMotionAnchor? anchor;
}

typedef ReadLiveMotionSample =
    Future<LiveMotionSample?> Function(VideoPlayerController);

class LiveMotionClip {
  const LiveMotionClip(this.bytes, {this.prebufferMillis = 0});
  final Uint8List bytes;
  final int prebufferMillis;
}

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
      sample: _readSample,
      snapshot: (player) => _readFrame(player, 'snapshot'),
      recordClip: recordClips ? _readClip : null,
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
      saveClip: (eventId, clip) => events.attachPhoneMotionClip(
        cameraId: camera.id,
        eventId: eventId,
        mp4: clip.bytes,
        prebufferMillis: clip.prebufferMillis,
      ),
    );
  }

  static const _channel = MethodChannel('safehood/camera_frame');
  static const _sampleInterval = Duration(milliseconds: 800);
  static const _sendInterval = Duration(seconds: 30);
  final CameraLiveSession _session;
  final ReadLiveMotionSample _sample;
  final LiveMotionFrame _snapshot;
  final SaveLiveMotion _save;
  final RecordLiveMotionClip? _recordClip;
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
  LiveMotionAnchor? _candidateAnchor;
  DateTime? _candidateTime;

  static Future<LiveMotionClip?> _readClip(
    VideoPlayerController player,
    LiveMotionAnchor? anchor,
  ) async {
    final session = CameraLivePlayback.frameSessionFor(player);
    if (session == null) return null;
    final data = await _channel.invokeMapMethod<String, dynamic>('clip', {
      'session': session,
      if (anchor != null) 'anchorUs': anchor.timeUs,
      if (anchor != null) 'anchorEpoch': anchor.epoch,
    });
    if (data == null ||
        data['bytes'] is! Uint8List ||
        data['prebufferMillis'] is! int) {
      return null;
    }
    return LiveMotionClip(
      data['bytes'] as Uint8List,
      prebufferMillis: data['prebufferMillis'] as int,
    );
  }

  static Future<LiveMotionSample?> _readSample(
    VideoPlayerController player,
  ) async {
    final session = CameraLivePlayback.frameSessionFor(player);
    if (session == null) return null;
    final data = await _channel.invokeMapMethod<String, dynamic>(
      'sampleTimed',
      {'session': session},
    );
    if (data == null || data['pixels'] is! Uint8List) return null;
    return LiveMotionSample(
      data['pixels'] as Uint8List,
      anchor: data['anchorUs'] is int && data['anchorEpoch'] is int
          ? LiveMotionAnchor(
              data['anchorUs'] as int,
              data['anchorEpoch'] as int,
            )
          : null,
    );
  }

  void _resetMotion() {
    _detector.reset();
    _candidateAnchor = null;
    _candidateTime = null;
  }

  static Future<Uint8List?> _readFrame(
    VideoPlayerController player,
    String method,
  ) async {
    final session = CameraLivePlayback.frameSessionFor(player);
    final size = player.value.size;
    if (session == null || size.isEmpty || !size.isFinite) return null;
    const maxEdge = 480.0;
    final scale = math.min(1.0, maxEdge / math.max(size.width, size.height));
    int dimension(double value) => math.max(1, (value * scale).round());
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
    _resetMotion();
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
        _resetMotion();
        _misses = 0;
        value = LiveMotionStatus.waiting;
        return;
      }

      LiveMotionSample? frame;
      try {
        frame = await _sample(player).timeout(const Duration(seconds: 2));
      } catch (_) {
        frame = null;
      }
      if (!current() || !_ready(player)) return;
      if (frame == null || frame.pixels.length != LiveMotionDetector.pixels) {
        _resetMotion();
        if (++_misses >= 6) value = LiveMotionStatus.unavailable;
        return;
      }

      _misses = 0;
      if (value == LiveMotionStatus.waiting ||
          value == LiveMotionStatus.unavailable) {
        value = LiveMotionStatus.watching;
      }
      if (!_detector.add(frame.pixels)) {
        if (_detector.hasPendingMotion) {
          _candidateAnchor ??= frame.anchor;
          _candidateTime ??= DateTime.now();
        } else {
          _candidateAnchor = null;
          _candidateTime = null;
        }
        return;
      }
      final anchor = _candidateAnchor ?? frame.anchor;
      final occurredAt = _candidateTime ?? DateTime.now();
      _candidateAnchor = null;
      _candidateTime = null;
      if (_sinceLastEvent.isRunning &&
          _sinceLastEvent.elapsed < _sendInterval) {
        return;
      }
      value = LiveMotionStatus.saving;
      final jpeg = await _tryRead(_snapshot, player);
      if (!current()) return;
      // A visual-only detection is untrusted if its frame cannot be read or
      // the native sampler rejected a corrupt image. Don't publish an alarm.
      if (!_ready(player) || jpeg == null) {
        _resetMotion();
        value = LiveMotionStatus.waiting;
        return;
      }

      _sinceLastEvent
        ..reset()
        ..start();
      final recording = _captureClip(player, generation, anchor);
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

  Future<LiveMotionClip?> _captureClip(
    VideoPlayerController player,
    int generation,
    LiveMotionAnchor? anchor,
  ) async {
    final record = _recordClip;
    if (record == null || _saveClip == null) return null;
    try {
      final clip = await record(
        player,
        anchor,
      ).timeout(const Duration(seconds: 11));
      if (!_current(player, generation)) return null;
      if (clip != null &&
          clip.bytes.length >= 100 &&
          clip.bytes.length <= 6 * 1024 * 1024 &&
          clip.prebufferMillis >= 0 &&
          clip.prebufferMillis <= 5000) {
        return clip;
      }
      debugPrint('PHONE MOTION RECORDING: clip unavailable');
    } catch (error) {
      debugPrint('PHONE MOTION RECORDING: ${error.runtimeType}');
    }
    return null;
  }

  Future<void> _attachClip(String eventId, LiveMotionClip clip) async {
    try {
      await _saveClip?.call(eventId, clip);
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
