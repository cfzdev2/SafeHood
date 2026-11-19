import 'dart:async';

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
  retryScheduled,
  unavailable,
}

typedef CameraLivePlaybackFactory =
    CameraLivePlayback Function(
      CameraProvider provider, {
      CameraPlaybackAttempt? preferred,
    });

/// Owns the player and provider for one live camera view.
class CameraLiveSession extends ChangeNotifier {
  CameraLiveSession(
    this._provider, {
    this.onAvailabilityChanged,
    this._createPlayback = CameraLivePlayback.new,
  });

  final CameraProvider _provider;
  final void Function(bool isOnline)? onAvailabilityChanged;
  final CameraLivePlaybackFactory _createPlayback;

  static const _retrySeconds = [2, 4, 8, 15, 30];
  static const _watchdogInterval = Duration(seconds: 5);
  static const _closeTimeout = Duration(seconds: 3);

  CameraLivePhase _phase = CameraLivePhase.idle;
  CameraLivePhase get phase => _phase;
  Object? _error;
  Object? get error => _error;
  VideoPlayerController? _controller;
  VideoPlayerController? get controller => _controller;
  bool get isConnecting =>
      phase == CameraLivePhase.connecting ||
      phase == CameraLivePhase.reconnecting;

  bool get _autoReconnect => _provider.camera.usesLocalConnection;

  CameraLivePlayback? _playback;
  CameraPlaybackAttempt? _preferred;
  Timer? _retryTimer;
  Timer? _watchdog;
  Future<void> _pending = Future<void>.value();
  Duration? _lastPosition;
  int _stalledChecks = 0;
  int _movingChecks = 0;
  int _retryIndex = 0;
  int _generation = 0;
  bool? _lastReportedAvailability;
  bool _hadProgress = false;
  bool _active = false;
  bool _closed = false;
  bool _userPaused = false;
  double _volume = 1;

  Future<void> resume() {
    if (_closed || _active) return Future<void>.value();
    _active = true;
    _retryIndex = 0;
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
    _lastPosition = player.value.position;
    _movingChecks = 0;
    _stalledChecks = 0;
    try {
      if (_userPaused) {
        await player.pause();
      } else if (player.value.hasError ||
          (_autoReconnect && player.value.isCompleted)) {
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

  Future<void> _begin({required bool reconnecting, bool alternate = false}) {
    _cancelRetry();
    final generation = ++_generation;
    if (!alternate) _playback = null;
    final attempt = _enqueue(() => _open(generation, alternate));
    _update(
      reconnecting ? CameraLivePhase.reconnecting : CameraLivePhase.connecting,
    );
    return attempt;
  }

  Future<void> _open(int generation, bool alternate) async {
    bool isCurrent() => _active && generation == _generation;
    if (!isCurrent()) return;

    VideoPlayerController? player;
    var startedProvider = false;
    try {
      if (!alternate) {
        await _provider.connect();
        if (!isCurrent()) return;
        _playback = _createPlayback(_provider, preferred: _preferred);
      }
      player = await _playback!.openNext(isActive: isCurrent, volume: _volume);
      if (player == null || !isCurrent()) return;

      startedProvider = true;
      await _provider.startLive();
      if (!isCurrent()) return;

      _controller = player;
      player = null;
      _controller!.addListener(_handlePlayerChange);
      _lastPosition = _controller!.value.position;
      _watchdog = Timer.periodic(_watchdogInterval, (_) => _checkProgress());
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
    if (value.hasError || (_autoReconnect && value.isCompleted)) {
      _interrupted('Odtwarzacz przerwał podgląd.');
    }
  }

  void _checkProgress() {
    final value = _controller?.value;
    if (value == null || !_active || _userPaused) return;
    if (value.hasError || (_autoReconnect && value.isCompleted)) {
      _handlePlayerChange();
      return;
    }

    if (value.isInitialized && value.position != _lastPosition) {
      _lastPosition = value.position;
      _stalledChecks = 0;
      _hadProgress = true;
      _preferred = _playback?.openedAttempt;
      // Don't reset the delay for connections that open and stall repeatedly.
      if (++_movingChecks >= 2) _retryIndex = 0;
      if (_autoReconnect) _reportAvailability(true);
    } else {
      _movingChecks = 0;
      if (++_stalledChecks >= 3) {
        _interrupted('Strumień LIVE przestał przesyłać obraz.');
      }
    }
  }

  void _interrupted(String message) {
    final alternate =
        _playback?.hasNext == true && (!_autoReconnect || !_hadProgress);
    final previous = _detachController();
    if (previous == null) return;
    unawaited(_enqueue(() => _release(previous)));
    if (alternate) {
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
    _lastPosition = null;
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
