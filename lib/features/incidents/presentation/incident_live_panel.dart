import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../cameras/data/camera_live_playback.dart';
import '../../cameras/data/camera_live_session.dart';
import '../../cameras/data/camera_provider_factory.dart';
import '../../cameras/data/camera_service.dart';
import '../../cameras/presentation/widgets/camera_live_placeholder.dart';
import '../../cameras/presentation/widgets/camera_live_refresh_button.dart';
import '../data/incident_live_service.dart';
import '../domain/incident.dart';

class IncidentLivePanel extends StatefulWidget {
  const IncidentLivePanel({super.key, required this.incident});

  final Incident incident;

  @override
  State<IncidentLivePanel> createState() => _IncidentLivePanelState();
}

class _IncidentLivePanelState extends State<IncidentLivePanel>
    with
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin<IncidentLivePanel> {
  final _relay = IncidentLiveService();
  final _auth = FirebaseAuth.instance;
  final _captureDelay = const Duration(milliseconds: 650);
  StreamSubscription<User?>? _authChanges;
  StreamSubscription<IncidentLiveFrame?>? _frames;
  Timer? _incidentExpiry;
  Timer? _frameExpiry;
  Timer? _retry;
  Timer? _capture;
  CameraLiveSession? _session;
  IncidentLiveFrame? _frame;
  String? _uid;
  String? _shareId;
  String? _shareError;
  String? _cameraError;
  int _visibility = 0;
  int _shareAttempt = 0;
  bool _active = false;
  bool _foreground = true;
  bool _routeCurrent = false;
  bool _startingShare = false;
  bool _closed = false;

  Incident get _incident => widget.incident;
  bool get _isOwner => _uid == _incident.reporterId;
  bool get _isOpen =>
      _incident.status == IncidentStatus.active &&
      (_incident.expiresAt?.isAfter(DateTime.now()) ?? false);
  bool get _canWatch =>
      _isOpen && _uid != null && _incident.participantIds.contains(_uid);
  bool get _canShare =>
      _active &&
      _canWatch &&
      _isOwner &&
      _auth.currentUser?.uid == _uid &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _uid = _auth.currentUser?.uid;
    _authChanges = _auth.authStateChanges().listen((user) {
      if (_closed || user?.uid == _uid) return;
      _leave();
      _uid = user?.uid;
      _sync();
      _redraw();
    });
    final expires = _incident.expiresAt;
    if (expires != null) {
      _incidentExpiry = Timer(expires.difference(DateTime.now()), _sync);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _redraw() {
    if (mounted && !_closed) setState(() {});
  }

  void _sync() {
    if (_closed) return;
    final visible = _foreground && _routeCurrent && _canWatch;
    if (visible == _active) return;
    if (!visible) {
      _leave();
    } else {
      _active = true;
      final generation = ++_visibility;
      if (_isOwner) {
        unawaited(_openOwnerPreview(generation));
      } else {
        _watchFrames(generation);
      }
    }
    _redraw();
  }

  bool _current(int generation) =>
      !_closed &&
      _active &&
      _visibility == generation &&
      _canWatch &&
      _auth.currentUser?.uid == _uid;

  Future<void> _openOwnerPreview(int generation) async {
    try {
      final camera = await CameraService()
          .getCamera(_incident.cameraId)
          .timeout(const Duration(seconds: 10));
      if (!_current(generation) || !_isOwner) return;
      if (camera == null) {
        throw StateError('Brak kamery zgłoszenia.');
      }
      final session = CameraLiveSession(
        CameraProviderFactory.create(camera),
        initialVolume: 0,
      );
      _session = session..addListener(_redraw);
      _redraw();
      await session.resume();
    } catch (error) {
      if (!_current(generation)) return;
      _cameraError = 'Brak podglądu z kamery zgłoszenia.';
      _redraw();
    }
  }

  void _watchFrames(int generation) {
    if (!_current(generation) || _isOwner) return;
    _frames = _relay
        .watch(_incident.id)
        .listen(
          (frame) {
            if (!_current(generation)) return;
            _frameExpiry?.cancel();
            final remaining = frame?.validUntil.difference(DateTime.now());
            _frame = remaining != null && remaining > Duration.zero
                ? frame
                : null;
            if (_frame != null) {
              _frameExpiry = Timer(
                Duration(
                  milliseconds: math.min(12000, remaining!.inMilliseconds),
                ),
                () {
                  _frame = null;
                  _redraw();
                },
              );
            }
            _redraw();
          },
          onError: (Object _) {
            if (!_current(generation)) return;
            _frameExpiry?.cancel();
            _frame = null;
            _frames = null;
            _redraw();
            // A stale lease can end a Firestore listener. The owner may share again.
            _retry = Timer(
              const Duration(seconds: 3),
              () => _watchFrames(generation),
            );
          },
          cancelOnError: true,
        );
  }

  bool _supportsCapture(VideoPlayerController? player) =>
      player != null && CameraLivePlayback.frameSessionFor(player) != null;

  bool _hasFrame(VideoPlayerController? player) =>
      player != null &&
      player.value.isPlaying &&
      !player.value.isBuffering &&
      !player.value.hasError &&
      _supportsCapture(player);

  Future<void> _startSharing() async {
    if (!_canShare ||
        !_supportsCapture(_session?.controller) ||
        _startingShare) {
      return;
    }
    final attempt = ++_shareAttempt;
    _startingShare = true;
    _shareError = null;
    _redraw();
    try {
      final id = await _relay.start(_incident.id);
      if (!_canShare || attempt != _shareAttempt) {
        await _releaseShare(id);
        return;
      }
      _shareId = id;
      unawaited(_publish(attempt, id));
    } catch (_) {
      if (attempt == _shareAttempt && _canShare) {
        _shareError = 'Nie udało się udostępnić obrazu.';
      }
    } finally {
      if (attempt == _shareAttempt) {
        _startingShare = false;
        _redraw();
      }
    }
  }

  Future<void> _publish(int attempt, String id, [int misses = 0]) async {
    bool current() => _canShare && _shareAttempt == attempt && _shareId == id;
    if (!current()) return;
    try {
      final player = _session?.controller;
      final jpeg = _hasFrame(player)
          ? await CameraLivePlayback.readShareFrame(
              player!,
            ).timeout(const Duration(milliseconds: 1500))
          : null;
      if (!current()) return;
      if (jpeg == null || !identical(player, _session?.controller)) {
        if (++misses >= 6) throw StateError('Brak obrazu.');
      } else {
        await _relay.send(_incident.id, id, jpeg);
        misses = 0;
      }
      if (current()) {
        _capture = Timer(_captureDelay, () => _publish(attempt, id, misses));
      }
    } catch (_) {
      if (current()) {
        _stopSharing();
        _shareError = 'Udostępnianie przerwane. Możesz uruchomić je ponownie.';
        _redraw();
      }
    }
  }

  Future<void> _releaseShare(String id) async {
    try {
      await _relay.stop(_incident.id, id);
    } catch (_) {
      // The publisher lease also expires if the phone loses its connection.
    }
  }

  void _stopSharing() {
    _shareAttempt++;
    _startingShare = false;
    _capture?.cancel();
    final id = _shareId;
    _shareId = null;
    if (id != null) unawaited(_releaseShare(id));
  }

  void _leave() {
    _visibility++;
    _active = false;
    _stopSharing();
    _frameExpiry?.cancel();
    _retry?.cancel();
    unawaited(_frames?.cancel());
    _frames = null;
    _frame = null;
    _cameraError = null;
    _shareError = null;
    _session?.removeListener(_redraw);
    _session?.dispose();
    _session = null;
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _incidentExpiry?.cancel();
    unawaited(_authChanges?.cancel());
    _leave();
    super.dispose();
  }

  Widget _picture() {
    if (!_isOpen) return _message('Transmisja zakończona.');
    if (!_canWatch) return _message('Brak dostępu do transmisji.');
    if (!_isOwner) {
      final frame = _frame;
      return frame == null
          ? _message('Czekam, aż autor zgłoszenia udostępni obraz.')
          : Image.memory(
              frame.jpeg,
              cacheWidth: 320,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            );
    }
    final session = _session;
    if (session == null) {
      return _message(_cameraError ?? 'Łączenie z kamerą…');
    }
    final player = session.controller;
    if (player == null) {
      return CameraLivePlaceholder(session: session, color: Colors.white70);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: player.value.size.width,
            height: player.value.size.height,
            child: VideoPlayer(player),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: CameraLiveRefreshButton(session: session),
        ),
      ],
    );
  }

  Widget _message(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70),
      ),
    ),
  );

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(color: Colors.black87, child: _picture()),
          ),
        ),
        if (_canShare) ...[
          const SizedBox(height: 8),
          if (_shareId != null || _startingShare)
            OutlinedButton(
              onPressed: () {
                _stopSharing();
                _redraw();
              },
              child: const Text('Zakończ udostępnianie'),
            )
          else
            FilledButton.icon(
              onPressed: _supportsCapture(_session?.controller)
                  ? _startSharing
                  : null,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Udostępnij obraz uczestnikom'),
            ),
          if (_shareId != null)
            const Text('Uczestnicy widzą obraz z tego zgłoszenia bez dźwięku.'),
          if (_shareError case final error?) Text(error),
        ],
      ],
    );
  }
}
