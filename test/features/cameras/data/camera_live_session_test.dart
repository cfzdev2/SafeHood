import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/camera_events/presentation/camera_event_live_screen.dart';
import 'package:safehood/features/cameras/data/camera_live_playback.dart';
import 'package:safehood/features/cameras/data/camera_live_session.dart';
import 'package:safehood/features/cameras/data/local_camera_connection.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/domain/camera_provider.dart';
import 'package:video_player/video_player.dart';

void main() {
  testWidgets('reopens fullscreen after the Wi-Fi camera returns', (
    tester,
  ) async {
    final provider = _Provider();
    final availability = <bool>[];
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
      onAvailabilityChanged: availability.add,
    );
    await session.resume();
    await tester.pumpWidget(
      MaterialApp(home: CameraFullscreenLiveView.live(session: session)),
    );
    final initial = provider.players.single;
    expect(find.byType(VideoPlayer), findsOneWidget);
    await session.setVolume(0);
    initial.advance();
    await tester.pump(const Duration(seconds: 5));
    expect(availability, [true]);

    provider.connectionError = TimeoutException('Wi-Fi lost');
    initial.fail();
    await tester.pump();
    expect(initial.disposed, isTrue);
    expect(find.byType(VideoPlayer), findsNothing);
    expect(
      find.textContaining('ponowi połączenie automatycznie'),
      findsOneWidget,
    );
    expect(availability, [true, false]);

    await tester.pump(const Duration(seconds: 2));
    expect(provider.connects, 2);
    expect(provider.players, hasLength(1));
    provider.connectionError = null;

    await tester.pump(const Duration(seconds: 3));
    expect(provider.connects, 2);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(provider.connects, 3);
    expect(provider.preferred.last, same(initial.attempt));
    expect(find.byType(VideoPlayer), findsOneWidget);
    final replacement = provider.players.last;
    expect(
      tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller,
      same(replacement),
    );
    expect(replacement.value.volume, 0);
    replacement.advance();
    await tester.pump(const Duration(seconds: 5));
    expect(availability, [true, false, true]);

    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    await tester.pump();
  });

  testWidgets('a freeze tries the other stream, and suspension stops retries', (
    tester,
  ) async {
    final provider = _Provider(choices: 2);
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
    );
    await session.resume();
    final initial = provider.players.single;

    await session.togglePlayback();
    await tester.pump(const Duration(seconds: 15));
    expect(session.controller, same(initial));
    await session.togglePlayback();

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(initial.disposed, isTrue);
    expect(provider.connects, 1);
    expect(provider.players, hasLength(2));
    expect(session.controller, same(provider.players.last));

    await tester.pump(const Duration(seconds: 15));
    expect(session.phase, CameraLivePhase.retryScheduled);
    await session.suspend();
    await tester.pump(const Duration(minutes: 1));
    expect(provider.connects, 1);
    expect(session.controller, isNull);

    await session.resume();
    expect(provider.connects, 2);
    final resumed = provider.players.last;
    resumed.fail();
    await tester.pump();
    provider.players.last.fail(); // Exhaust the alternate as well.
    session.dispose();
    await tester.pump(const Duration(minutes: 1));
    expect(provider.connects, 2);
    expect(provider.players.every((player) => player.disposed), isTrue);
  });

  testWidgets('returning during start waits for the stale player to close', (
    tester,
  ) async {
    final starting = Completer<void>();
    final provider = _Provider()..pendingStart = starting;
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
    );
    final originalOpen = session.resume();
    await tester.pump();
    expect(provider.calls, ['connect', 'start']);
    final initial = provider.players.single;

    await session.suspend();
    final newOpen = session.resume();
    await tester.pump();
    expect(provider.calls, ['connect', 'start']);
    expect(session.controller, isNull);

    starting.complete();
    await originalOpen;
    await newOpen;
    expect(provider.calls, ['connect', 'start', 'stop', 'connect', 'start']);
    expect(initial.disposed, isTrue);
    expect(session.controller, same(provider.players.last));

    session.dispose();
    await tester.pump();
  });

  testWidgets('configuration errors wait for an explicit retry', (
    tester,
  ) async {
    final provider = _Provider()
      ..connectionError = const CameraConnectionIssue(
        'Brak danych kamery.',
        retryable: false,
      );
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
    );
    await session.resume();
    expect(session.phase, CameraLivePhase.unavailable);
    await tester.pump(const Duration(minutes: 1));
    expect(provider.connects, 1);

    provider.connectionError = null;
    await session.retry();
    expect(session.phase, CameraLivePhase.playing);
    expect(provider.connects, 2);

    session.dispose();
    await tester.pump();
  });
}

class _Provider extends Fake implements CameraProvider {
  _Provider({this.choices = 1});

  final int choices;
  final calls = <String>[];
  final players = <_Player>[];
  final preferred = <CameraPlaybackAttempt?>[];
  Object? connectionError;
  Completer<void>? pendingStart;
  int connects = 0;

  @override
  final camera = const Camera(
    id: 'camera-test',
    name: 'Kamera',
    locationName: 'Dom',
    brand: 'Test',
    model: 'Test',
    isOnline: false,
    motionDetectionEnabled: false,
    hasSdCard: false,
    connectionType: CameraConnectionType.onvif,
  );

  @override
  Uri? get liveStreamUri => null;

  @override
  Future<void> connect() async {
    connects++;
    calls.add('connect');
    if (connectionError case final Object error) throw error;
  }

  @override
  Future<void> startLive() async {
    calls.add('start');
    final pending = pendingStart;
    pendingStart = null;
    await pending?.future;
  }

  @override
  Future<void> stopLive() async => calls.add('stop');

  @override
  Future<void> disconnect() async => calls.add('disconnect');

  @override
  Future<void> dispose() async => calls.add('dispose');

  CameraLivePlayback createPlayback(
    CameraProvider provider, {
    CameraPlaybackAttempt? preferred,
  }) {
    this.preferred.add(preferred);
    return _Playback(this, choices);
  }
}

class _Playback extends CameraLivePlayback {
  _Playback(this.provider, this._remaining) : super(provider);
  final _Provider provider;
  int _remaining;

  @override
  bool get hasNext => _remaining > 0;

  @override
  CameraPlaybackAttempt? openedAttempt;

  @override
  Future<VideoPlayerController?> openNext({
    required bool Function() isActive,
    required double volume,
  }) async {
    if (!isActive()) return null;
    _remaining--;
    final attempt = CameraPlaybackAttempt(
      Uri.parse('rtsp://192.168.1.9/profile-$_remaining'),
      CameraRtspTransport.tcp,
    );
    final player = _Player(attempt);
    await player.setVolume(volume);
    openedAttempt = attempt;
    provider.players.add(player);
    return player;
  }
}

class _Player extends VideoPlayerController {
  _Player(this.attempt) : super.networkUrl(attempt.uri) {
    value = const VideoPlayerValue(
      duration: Duration(minutes: 2),
      size: Size(1280, 720),
      isInitialized: true,
      isPlaying: true,
    );
  }

  final CameraPlaybackAttempt attempt;
  bool disposed = false;

  void advance() {
    value = value.copyWith(
      position: value.position + const Duration(seconds: 1),
    );
  }

  void fail() {
    value = value.copyWith(
      isPlaying: false,
      errorDescription: 'Connection lost',
    );
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    value = value.copyWith(volume: volume);
  }

  @override
  Future<void> dispose() {
    disposed = true;
    return super.dispose();
  }
}
