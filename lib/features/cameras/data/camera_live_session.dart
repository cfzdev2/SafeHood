import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../domain/camera_provider.dart';
import 'camera_live_playback.dart';
import 'local_camera_connection.dart';

enum CameraLivePhase {
  idle,
  connecting,
  playing,
  reconnecting,
  adjustingQuality,
  retryScheduled,
  unavailable,
}

typedef CameraLivePlaybackFactory =
    CameraLivePlayback Function(
      CameraProvider provider, {
      CameraPlaybackAttempt? preferred,
      CameraLiveQualityProfile? qualityProfile,
    });

/// Owns the player and provider for one live camera view.
class CameraLiveSession extends ChangeNotifier {
  CameraLiveSession(
    this._provider, {
    this.onAvailabilityChanged,
    this._createPlayback = CameraLivePlayback.new,
    this._qualityStore = const LocalCameraConnectionStore(),
    this._readFrameStats = CameraLivePlayback.readFrameStats,
    double initialVolume = 1,
  }) : _volume = initialVolume;

  final CameraProvider _provider;
  final void Function(bool isOnline)? onAvailabilityChanged;
  final CameraLivePlaybackFactory _createPlayback;
  final CameraLiveQualityStore _qualityStore;
  final Future<CameraLiveFrameStats?> Function(VideoPlayerController)
  _readFrameStats;

  static const _retrySeconds = [2, 4, 8, 15, 30];
  static const _watchdogInterval = Duration(seconds: 5);
  static const _positionDeadline = Duration(seconds: 1);
  static const _slowChecksBeforeRefresh = 3;
  static const _stableChecksBeforeReset = 12;
  static const _closeTimeout = Duration(seconds: 3);
  static const _bufferingThreshold = Duration(seconds: 4);
  static const _qualityDeadline = Duration(seconds: 6);

  CameraLivePhase _phase = CameraLivePhase.idle;
  CameraLivePhase get phase => _phase;
  Object? _error;
  Object? get error => _error;
  VideoPlayerController? _controller;
  VideoPlayerController? get controller => _controller;
  bool get isConnecting =>
      phase == CameraLivePhase.connecting ||
      phase == CameraLivePhase.reconnecting ||
      phase == CameraLivePhase.adjustingQuality;

  bool get canRefresh =>
      _active &&
      _autoReconnect &&
      phase == CameraLivePhase.playing &&
      _controller != null;

  bool get _autoReconnect => _provider.camera.usesLocalConnection;
  bool get _isRtsp => _playback?.openedAttempt?.uri.scheme == 'rtsp';

  bool _hasEnded(VideoPlayerValue value) =>
      _autoReconnect && !_isRtsp && value.isCompleted;

  CameraLiveQualitySource? get _qualitySource =>
      _autoReconnect && _provider is CameraLiveQualitySource
      ? _provider as CameraLiveQualitySource
      : null;

  CameraLivePlayback? _playback;
  CameraPlaybackAttempt? _preferred;
  Timer? _retryTimer;
  Timer? _watchdog;
  Timer? _bufferingTimer;
  VideoPlayerController? _qualityProbePlayer;
  Uri? _recentStallStream;
  final _probedStreams = <Uri>{};
  int _recentStalls = 0;
  bool _bufferingStallCounted = false;
  bool _qualityLoaded = false;
  int? _savedQualityPixels;
  bool _skipSavedQuality = false;
  Future<void> _pending = Future<void>.value();
  Duration? _lastPosition;
  CameraLiveFrameStats? _lastFrameStats;
  bool _reportedSlowFrames = false;
  int _slowFrameChecks = 0;
  bool _refreshedSlowStream = false;
  int _stalledChecks = 0;
  int _movingChecks = 0;
  int _retryIndex = 0;
  int _generation = 0;
  bool? _lastReportedAvailability;
  bool _hadProgress = false;
  bool _active = false;
  bool _closed = false;
  bool _userPaused = false;
  double _volume;

  Future<void> resume() {
    if (_closed || _active) return Future<void>.value();
    _active = true;
    _retryIndex = 0;
    _qualityLoaded = false;
    _skipSavedQuality = false;
    _probedStreams.clear();
    _recentStallStream = null;
    _recentStalls = 0;
    _refreshedSlowStream = false;
    return _begin(reconnecting: false);
  }

  Future<void> suspend() {
    if (!_active) return Future<void>.value();
    _active = false;
    _generation++;
    _cancelRetry();
    final previous = _detachController();
    _playback = null;
    // Navigation needn't wait on a network request that hasn't opened video.
    final closing = previous == null
        ? Future<void>.value()
        : _enqueue(() => _release(previous));
    _update(CameraLivePhase.idle);
    return closing;
  }

  Future<void> retry() {
    if (!_active ||
        (phase != CameraLivePhase.retryScheduled &&
            phase != CameraLivePhase.unavailable)) {
      return Future<void>.value();
    }
    _retryIndex = 0;
    return _begin(reconnecting: true);
  }

  void refresh() {
    if (!canRefresh) return;
    _refreshedSlowStream = true;
    _retryIndex = 0;
    _interrupted('Ręczne odświeżenie podglądu.', reopen: true);
  }

  Future<void> setVolume(double volume) async {
    final player = _controller;
    if (player == null) return;
    await player.setVolume(volume);
    _volume = volume;
  }

  Future<void> togglePlayback() async {
    final player = _controller;
    if (player == null) return;
    _userPaused = player.value.isPlaying;
    _endBufferingEpisode();
    _resetFrameStats();
    if (!_isRtsp) _lastPosition = player.value.position;
    _movingChecks = 0;
    _stalledChecks = 0;
    try {
      if (_userPaused) {
        await player.pause();
      } else if (player.value.hasError || _hasEnded(player.value)) {
        _handlePlayerChange();
      } else {
        await player.play();
      }
    } catch (_) {
      if (identical(player, _controller)) {
        _interrupted('Odtwarzacz przerwał podgląd.');
      }
    }
  }

  Future<void> _begin({
    required bool reconnecting,
    bool alternate = false,
    CameraLiveQualityProfile? qualityProfile,
  }) {
    _cancelRetry();
    final generation = ++_generation;
    if (!alternate) _playback = null;
    final attempt = _enqueue(
      () => _open(generation, alternate, qualityProfile),
    );
    _update(
      qualityProfile != null
          ? CameraLivePhase.adjustingQuality
          : reconnecting
          ? CameraLivePhase.reconnecting
          : CameraLivePhase.connecting,
    );
    return attempt;
  }

  Future<void> _open(
    int generation,
    bool alternate,
    CameraLiveQualityProfile? qualityProfile,
  ) async {
    bool isCurrent() => _active && generation == _generation;
    if (!isCurrent()) return;

    VideoPlayerController? player;
    var startedProvider = false;
    var usingSavedQuality = false;
    try {
      if (!alternate) {
        if (qualityProfile == null) {
          await _provider.connect();
          if (!isCurrent()) return;
          if (_qualitySource != null && !_qualityLoaded) {
            final saved = await _readQuality();
            if (!isCurrent()) return;
            _savedQualityPixels = saved;
            _qualityLoaded = true;
          }
          if (_savedQualityPixels case final int pixels
              when !_skipSavedQuality) {
            qualityProfile = await _findQuality(pixels);
            if (!isCurrent()) return;
            usingSavedQuality = true;
          }
        }
        _playback = _createPlayback(
          _provider,
          preferred: _preferred,
          qualityProfile: qualityProfile,
        );
      }
      player = await _playback!.openNext(isActive: isCurrent, volume: _volume);
      if (player == null || !isCurrent()) return;
      if (usingSavedQuality &&
          _playback?.openedAttempt?.qualityPixels == null) {
        // Keep a working original stream if the saved choice no longer opens.
        _skipSavedQuality = true;
      }

      startedProvider = true;
      await _provider.startLive();
      if (!isCurrent()) return;

      _controller = player;
      player = null;
      _controller!.addListener(_handlePlayerChange);
      _lastPosition = _isRtsp ? Duration.zero : _controller!.value.position;
      _watchdog = Timer.periodic(
        _watchdogInterval,
        (_) => unawaited(_checkProgress()),
      );
      _update(CameraLivePhase.playing);
      // RTSP setup can succeed before the first frame arrives.
      if (!_autoReconnect && isCurrent()) _reportAvailability(true);
      _handlePlayerChange();
    } catch (error) {
      if (isCurrent()) _failed(error);
    } finally {
      if (player != null) {
        await _disposePlayer(player);
        if (startedProvider) await _stopProvider();
      }
    }
  }

  void _handlePlayerChange() {
    final value = _controller?.value;
    if (value == null || !_active || _userPaused) return;
    if (value.hasError || _hasEnded(value)) {
      _interrupted('Odtwarzacz przerwał podgląd.');
      return;
    }
    if (!value.isBuffering) {
      _endBufferingEpisode();
      return;
    }
    _movingChecks = 0;
    _resetFrameStats();
    if (_hadProgress &&
        _qualitySource != null &&
        _bufferingTimer == null &&
        !_bufferingStallCounted) {
      _bufferingTimer = Timer(_bufferingThreshold, () {
        _bufferingTimer = null;
        if (_controller?.value.isBuffering != true || _userPaused) return;
        _noticeStall(frozen: false);
      });
    }
  }

  Future<void> _checkProgress() async {
    final player = _controller;
    if (player == null || !_active || _userPaused) return;

    // video_player clamps its UI position to the stream's reported duration
    // and sets isCompleted when they match. Neither represents the state of
    // an open-ended RTSP feed. Read the underlying playback clock instead.
    final (position, frameStats) = _isRtsp
        ? await (_readRtspPosition(player), _readLiveFrameStats(player)).wait
        : (player.value.position, null);
    if (!identical(player, _controller) || !_active || _userPaused) return;

    final value = player.value;
    if (value.hasError || _hasEnded(value)) {
      _handlePlayerChange();
      return;
    }

    if (position == null && value.isPlaying && !value.isBuffering) {
      // One unavailable clock reading is not evidence that video froze.
      _stalledChecks = 0;
      _resetFrameStats();
      return;
    }

    if (value.isInitialized && position != null && position != _lastPosition) {
      _lastPosition = position;
      _stalledChecks = 0;
      _hadProgress = true;
      _preferred = _playback?.openedAttempt;
      // Don't reset the delay for connections that open and stall repeatedly.
      if (value.isBuffering) {
        _handlePlayerChange();
      } else if (_renderingSlowly(frameStats)) {
        _movingChecks = 0;
        _slowFrameChecks++;
        _noticeStall(frozen: false);
        _refreshIfStillSlow();
      } else {
        _slowFrameChecks = 0;
        if (++_movingChecks >= 2) _retryIndex = 0;
        if (_movingChecks >= _stableChecksBeforeReset) {
          _recentStalls = 0;
          _refreshedSlowStream = false;
        }
        if (_movingChecks == 4) _rememberQuality(value);
      }
      if (_autoReconnect && identical(player, _controller)) {
        _reportAvailability(true);
      }
    } else {
      _movingChecks = 0;
      _resetFrameStats();
      if (++_stalledChecks >= 3) {
        _noticeStall(frozen: true);
      }
    }
  }

  Future<Duration?> _readRtspPosition(VideoPlayerController player) async {
    try {
      final position = await player.position.timeout(_positionDeadline);
      return position != null && !position.isNegative ? position : null;
    } catch (_) {
      return null;
    }
  }

  Future<CameraLiveFrameStats?> _readLiveFrameStats(
    VideoPlayerController player,
  ) async {
    if (!_autoReconnect ||
        !player.value.isPlaying ||
        player.value.isBuffering) {
      return null;
    }
    try {
      return await _readFrameStats(player).timeout(_positionDeadline);
    } catch (_) {
      return null;
    }
  }

  void _resetFrameStats() {
    _lastFrameStats = null;
    _reportedSlowFrames = false;
    _slowFrameChecks = 0;
  }

  void _refreshIfStillSlow() {
    if (!canRefresh ||
        _userPaused ||
        _qualityProbePlayer != null ||
        _slowFrameChecks < _slowChecksBeforeRefresh ||
        _refreshedSlowStream) {
      return;
    }
    // Rebuild the decoder once. A persistently slow camera must not loop
    // between playback and reconnecting; allow another try after stable video.
    _refreshedSlowStream = true;
    _interrupted(
      'Odtwarzanie nadal się zacina. Odświeżam podgląd.',
      reopen: true,
    );
  }

  bool _renderingSlowly(CameraLiveFrameStats? stats) {
    final previous = _lastFrameStats;
    _lastFrameStats = stats;
    if (stats == null || previous == null) return false;
    final elapsed = stats.atMillis - previous.atMillis;
    final rendered = stats.rendered - previous.rendered;
    final dropped = stats.dropped - previous.dropped;
    // Ignore a decoder reset or an interval interrupted by a lifecycle change.
    if (elapsed < 3000 || elapsed > 10000 || rendered < 0 || dropped < 0) {
      return false;
    }

    final fps = rendered * 1000 / elapsed;
    final minimumFps = math.min(5.0, (stats.expectedFps ?? 10.0) * 0.6);
    final slow = fps < minimumFps || (dropped >= 10 && dropped * 2 > rendered);
    if (slow && !_reportedSlowFrames) {
      debugPrint(
        'CAMERA LIVE [${_provider.camera.id}]: obraz ${fps.toStringAsFixed(1)} '
        'kl./s, pominięto $dropped klatek w ciągu ${elapsed / 1000} s.',
      );
    }
    _reportedSlowFrames = slow;
    return slow;
  }

  void _noticeStall({required bool frozen}) {
    final player = _controller;
    if (player == null || identical(player, _qualityProbePlayer)) return;
    final stream = _playback?.openedAttempt?.uri;
    final pixels = _framePixels(player.value);
    if (!_bufferingStallCounted &&
        _hadProgress &&
        _qualitySource != null &&
        stream != null &&
        pixels > 1) {
      _bufferingStallCounted = player.value.isBuffering;
      final identity = rtspStreamIdentity(stream);
      if (identity != _recentStallStream) {
        _recentStallStream = identity;
        _recentStalls = 0;
      }
      if (++_recentStalls >= 2 && _probedStreams.add(identity)) {
        _qualityProbePlayer = player;
        unawaited(_tryLighterStream(player, pixels - 1, stream));
        return;
      }
    }
    if (frozen) _interrupted('Strumień LIVE przestał przesyłać obraz.');
  }

  Future<void> _tryLighterStream(
    VideoPlayerController player,
    int maxPixels,
    Uri current,
  ) async {
    final profile = await _findQuality(maxPixels, excluding: current);
    if (!identical(_qualityProbePlayer, player)) return;
    _qualityProbePlayer = null;
    if (!identical(_controller, player) || _userPaused) return;
    if (profile != null) {
      debugPrint('CAMERA LIVE: próba lżejszego obrazu po zacięciach.');
      _interrupted('Dopasowywanie jakości obrazu.', qualityProfile: profile);
    } else if (_stalledChecks >= 3) {
      _interrupted('Strumień LIVE przestał przesyłać obraz.');
    } else {
      _refreshIfStillSlow();
    }
  }

  int _framePixels(VideoPlayerValue value) {
    final size = value.size;
    if (size.isEmpty || !size.isFinite) return 0;
    return (size.width * size.height).round();
  }

  Future<int?> _readQuality() async {
    try {
      return await _qualityStore
          .readLiveQuality(_provider.camera.id)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  Future<CameraLiveQualityProfile?> _findQuality(
    int maxPixels, {
    Uri? excluding,
  }) async {
    try {
      final profile = await _qualitySource
          ?.findLiveQualityProfile(maxPixels: maxPixels, excluding: excluding)
          .timeout(_qualityDeadline);
      if (profile == null ||
          profile.pixels <= 0 ||
          profile.pixels > maxPixels ||
          (excluding != null &&
              rtspStreamIdentity(profile.uri) ==
                  rtspStreamIdentity(excluding))) {
        return null;
      }
      return profile;
    } catch (_) {
      return null;
    }
  }

  void _rememberQuality(VideoPlayerValue value) {
    final target = _playback?.openedAttempt?.qualityPixels;
    final actual = _framePixels(value);
    if (target == null ||
        target == _savedQualityPixels ||
        actual <= 0 ||
        actual > target) {
      return;
    }
    _savedQualityPixels = target;
    _skipSavedQuality = false;
    unawaited(_writeQuality(target));
  }

  Future<void> _writeQuality(int pixels) async {
    try {
      await _qualityStore.writeLiveQuality(_provider.camera.id, pixels);
    } catch (_) {
      // Local preference writes cannot interrupt playback.
    }
  }

  void _endBufferingEpisode() {
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    _bufferingStallCounted = false;
  }

  void _interrupted(
    String message, {
    CameraLiveQualityProfile? qualityProfile,
    bool reopen = false,
  }) {
    final opened = _playback?.openedAttempt;
    final alternate =
        _playback?.hasNext == true && (!_autoReconnect || !_hadProgress);
    final previous = _detachController();
    if (previous == null) return;
    debugPrint('CAMERA LIVE [${_provider.camera.id}]: $message');
    unawaited(_enqueue(() => _release(previous)));
    if (qualityProfile != null) {
      unawaited(_begin(reconnecting: true, qualityProfile: qualityProfile));
    } else if (reopen) {
      _preferred = opened ?? _preferred;
      unawaited(_begin(reconnecting: true));
    } else if (alternate) {
      unawaited(_begin(reconnecting: true, alternate: true));
    } else {
      _playback = null;
      _failed(CameraConnectionIssue(message));
    }
  }

  void _failed(Object error) {
    debugPrint(
      'CAMERA LIVE ERROR [${_provider.camera.id}]: ${error.runtimeType}',
    );
    final retryable =
        _autoReconnect && (error is! CameraConnectionIssue || error.retryable);
    if (retryable) {
      final wait = Duration(seconds: _retrySeconds[_retryIndex]);
      if (_retryIndex < _retrySeconds.length - 1) _retryIndex++;
      _retryTimer = Timer(wait, () {
        _retryTimer = null;
        if (_active) unawaited(_begin(reconnecting: true));
      });
    }
    _update(
      retryable ? CameraLivePhase.retryScheduled : CameraLivePhase.unavailable,
      error: error,
    );
    if (_active) _reportAvailability(false);
  }

  void _update(CameraLivePhase phase, {Object? error}) {
    _phase = phase;
    _error = error;
    notifyListeners();
  }

  void _reportAvailability(bool isOnline) {
    if (isOnline == _lastReportedAvailability) return;
    _lastReportedAvailability = isOnline;
    onAvailabilityChanged?.call(isOnline);
  }

  VideoPlayerController? _detachController() {
    final previous = _controller;
    _controller = null;
    previous?.removeListener(_handlePlayerChange);
    _watchdog?.cancel();
    _watchdog = null;
    _endBufferingEpisode();
    _qualityProbePlayer = null;
    _lastPosition = null;
    _resetFrameStats();
    _stalledChecks = 0;
    _movingChecks = 0;
    _hadProgress = false;
    _userPaused = false;
    return previous;
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    // Provider connect/start/stop update shared state. A cancelled attempt must
    // finish cleaning up before the next one can open the same camera.
    return _pending = _pending.then((_) => operation()).catchError((Object e) {
      debugPrint('CAMERA LIVE CLEANUP ERROR: ${e.runtimeType}');
    });
  }

  Future<void> _disposePlayer(VideoPlayerController player) async {
    try {
      await player.dispose().timeout(_closeTimeout);
    } catch (_) {
      debugPrint('CAMERA LIVE: nie udało się zamknąć podglądu.');
    }
  }

  Future<void> _stopProvider() async {
    try {
      await _provider.stopLive();
    } catch (_) {
      // The remote session may already be closed.
    }
  }

  Future<void> _release(VideoPlayerController player) async {
    await _disposePlayer(player);
    await _stopProvider();
  }

  @override
  void dispose() {
    _closed = true;
    _active = false;
    _generation++;
    _cancelRetry();
    final previous = _detachController();
    _playback = null;
    _preferred = null;
    unawaited(
      _enqueue(() async {
        if (previous != null) await _release(previous);
        try {
          await _provider.disconnect();
        } finally {
          await _provider.dispose();
        }
      }),
    );
    super.dispose();
  }
}
