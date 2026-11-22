import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/camera_events/presentation/camera_event_live_screen.dart';
import 'package:safehood/features/cameras/data/camera_live_playback.dart';
import 'package:safehood/features/cameras/data/camera_live_session.dart';
import 'package:safehood/features/cameras/data/live_motion_detector.dart';
import 'package:safehood/features/cameras/data/live_motion_monitor.dart';
import 'package:safehood/features/cameras/data/local_camera_connection.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/domain/camera_provider.dart';
import 'package:video_player/video_player.dart';

void main() {
  testWidgets('a suspended view gives monitoring back to the phone service', (
    tester,
  ) async {
    const channel = MethodChannel('safehood/background_motion');
    final handovers = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      handovers.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final provider = _Provider();
    final view = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
    );

    await view.resume();
    await view.suspend();
    final emit = handovers.first.arguments as Map;
    expect(emit['cameraId'], provider.camera.id);
    expect(handovers.last.arguments, {'lease': emit['lease']});

    await view.resume();
    view.dispose();
    await tester.pump();
    final next = handovers[2].arguments as Map;
    expect(next['lease'], isNot(emit['lease']));
    expect(handovers.last.arguments, {'lease': next['lease']});
  });

  testWidgets('phone motion samples only while enabled and reports one event', (
    tester,
  ) async {
    final provider = _Provider();
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
    );
    final toggle = StreamController<bool>.broadcast();
    var samples = 0;
    final pictures = <Uint8List?>[];
    final snapshot = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
    final monitor = LiveMotionMonitor(
      session: session,
      enabled: toggle.stream,
      sample: (_) async => _motionFrame(++samples > 1),
      snapshot: (_) async => snapshot,
      save: (_, jpeg) async {
        pictures.add(jpeg);
        return 'event-1';
      },
    );
    await session.resume();
    await tester.pump(const Duration(seconds: 1));
    expect(samples, 0);

    toggle.add(true);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 800));
    }
    expect(pictures, [snapshot]);
    expect(monitor.value, LiveMotionStatus.saved);

    toggle.add(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(samples, 3);
    expect(monitor.value, LiveMotionStatus.off);
    monitor.dispose();
    session.dispose();
    unawaited(toggle.close());
    await tester.pump();
  });

  testWidgets('a frame in flight is discarded when playback is suspended', (
    tester,
  ) async {
    final provider = _Provider();
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
    );
    final pendingSnapshot = Completer<Uint8List?>();
    final toggle = StreamController<bool>.broadcast();
    var samples = 0;
    var reports = 0;
    final monitor = LiveMotionMonitor(
      session: session,
      enabled: toggle.stream,
      sample: (_) async => _motionFrame(++samples > 1),
      snapshot: (_) => pendingSnapshot.future,
      save: (_, _) async {
        reports++;
        return 'event-1';
      },
    );
    await session.resume();
    toggle.add(true);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 800));
    }
    expect(monitor.value, LiveMotionStatus.saving);
    await session.suspend();
    pendingSnapshot.complete(Uint8List(4));
    await tester.pump(const Duration(seconds: 3));
    expect(reports, 0);
    expect(samples, 3);
    monitor.dispose();
    session.dispose();
    unawaited(toggle.close());
    await tester.pump();
  });

  for (final leaveEarly in [false, true]) {
    testWidgets(
      leaveEarly
          ? 'closing the live view during capture keeps the event without video'
          : 'the event saves before a completed recording attaches to its ID',
      (tester) async {
        final provider = _Provider();
        final session = CameraLiveSession(
          provider,
          createPlayback: provider.createPlayback,
        );
        final toggle = StreamController<bool>.broadcast();
        final clip = Completer<Uint8List?>();
        final snapshot = Uint8List(20);
        final video = Uint8List(500);
        final saved = <Uint8List?>[];
        final uploads = <(String, Uint8List)>[];
        var frames = 0;
        var captures = 0;
        final monitor = LiveMotionMonitor(
          session: session,
          enabled: toggle.stream,
          sample: (_) async => _motionFrame(++frames > 1),
          snapshot: (_) async => snapshot,
          recordClip: (_) {
            captures++;
            return clip.future;
          },
          save: (_, picture) async {
            saved.add(picture);
            return 'recorded-motion';
          },
          saveClip: (eventId, bytes) async => uploads.add((eventId, bytes)),
        );
        await session.resume();
        toggle.add(true);
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 800));
        }
        expect(captures, 1);
        expect(saved, [snapshot]);
        expect(monitor.value, LiveMotionStatus.saved);
        expect(uploads, isEmpty);

        if (leaveEarly) await session.suspend();
        clip.complete(video);
        await tester.pump();
        expect(uploads, leaveEarly ? isEmpty : [('recorded-motion', video)]);
        monitor.dispose();
        session.dispose();
        unawaited(toggle.close());
        await tester.pump();
      },
    );
  }

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

  testWidgets('fullscreen refresh reopens the current live preview in place', (
    tester,
  ) async {
    final provider = _Provider();
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
    );
    await session.resume();
    await session.setVolume(0);
    await tester.pumpWidget(
      MaterialApp(home: CameraFullscreenLiveView.live(session: session)),
    );
    final original = provider.players.single;
    await tester.tap(find.byTooltip('Odśwież podgląd'));
    await tester.pump();
    await tester.pump();

    expect(original.disposed, isTrue);
    expect(provider.preferred.last, same(original.attempt));
    expect(provider.connects, 2);
    final replacement = provider.players.last;
    expect(replacement.value.volume, 0);
    expect(
      tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller,
      same(replacement),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    await tester.pump();
  });

  testWidgets('RTSP with a clamped position stays open until playback stops', (
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
    final cameraPlayer = provider.players.single;
    const reportedDuration = Duration(milliseconds: 1);
    for (var i = 1; i <= 5; i++) {
      cameraPlayer.rawPosition = Duration(seconds: i * 5);
      cameraPlayer.value = cameraPlayer.value.copyWith(
        duration: reportedDuration,
        position: reportedDuration,
        isCompleted: true,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(session.controller, same(cameraPlayer));
    }
    expect(availability, [true]);
    expect(cameraPlayer.disposed, isFalse);
    expect(provider.connects, 1);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(session.phase, CameraLivePhase.retryScheduled);
    expect(availability, [true, false]);
    expect(cameraPlayer.disposed, isTrue);
    session.dispose();
    await tester.pump();
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

  testWidgets(
    'repeated buffering tries a lighter profile and remembers it only after playback',
    (tester) async {
      final provider = _AdaptiveProvider();
      final store = _QualityStore();
      final session = CameraLiveSession(
        provider,
        createPlayback: provider.createPlayback,
        qualityStore: store,
      );
      await session.resume();
      final original = provider.players.single;
      original.advance();
      await tester.pump(const Duration(seconds: 5));

      original.buffer(true);
      await tester.pump(const Duration(seconds: 2));
      original.buffer(false);
      original.buffer(true);
      await tester.pump(const Duration(seconds: 4));
      original.buffer(false);
      expect(provider.requests, isEmpty);
      expect(session.controller, same(original));

      original.buffer(true);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(provider.requests, [(1280 * 720 - 1, original.attempt.uri)]);
      final lighter = provider.players.last;
      expect(lighter.attempt.uri, _lightProfile.uri);
      expect(session.controller, same(lighter));
      expect(original.disposed, isTrue);
      expect(provider.connects, 1);

      for (var i = 0; i < 3; ++i) {
        lighter.advance();
        await tester.pump(const Duration(seconds: 5));
      }
      expect(store.saved, isEmpty);
      lighter.advance();
      await tester.pump(const Duration(seconds: 5));
      expect(store.saved, {provider.camera.id: 640 * 360});
      session.dispose();
      await tester.pump();

      final reopenedProvider = _AdaptiveProvider();
      final reopened = CameraLiveSession(
        reopenedProvider,
        createPlayback: reopenedProvider.createPlayback,
        qualityStore: store,
      );
      await reopened.resume();
      expect(reopenedProvider.requests, [(640 * 360, null)]);
      expect(reopenedProvider.players.single.attempt.uri, _lightProfile.uri);

      reopened.dispose();
      await tester.pump();
    },
  );

  testWidgets('when no lighter stream is found the active player stays open', (
    tester,
  ) async {
    final provider = _AdaptiveProvider()..offered = null;
    final store = _QualityStore();
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
      qualityStore: store,
    );
    await session.resume();
    final original = provider.players.single;
    original.advance();
    await tester.pump(const Duration(seconds: 5));
    for (var i = 0; i < 2; ++i) {
      original.buffer(true);
      await tester.pump(const Duration(seconds: 4));
      original.buffer(false);
    }

    expect(provider.requests, hasLength(1));
    expect(session.controller, same(original));
    expect(original.disposed, isFalse);
    expect(store.saved, isEmpty);

    session.dispose();
    await tester.pump();
  });

  testWidgets(
    'few displayed frames can trigger a lighter stream with no freeze',
    (tester) async {
      final provider = _AdaptiveProvider();
      final store = _QualityStore();
      var time = 0;
      var rendered = 0;
      var dropped = 0;
      final session = CameraLiveSession(
        provider,
        createPlayback: provider.createPlayback,
        qualityStore: store,
        readFrameStats: (_) async => CameraLiveFrameStats(
          atMillis: time,
          rendered: rendered,
          dropped: dropped,
          expectedFps: 15,
        ),
      );
      await session.resume();
      final original = provider.players.single;

      Future<void> check(_Player player, int frames, {int skipped = 0}) async {
        time += 5000;
        rendered += frames;
        dropped += skipped;
        player.advance();
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
      }

      await check(original, 75);
      await check(original, 10);
      expect(session.controller, same(original));
      expect(provider.requests, isEmpty);

      await check(original, 30, skipped: 25);
      expect(provider.requests, [(1280 * 720 - 1, original.attempt.uri)]);
      final lighter = provider.players.last;
      expect(session.controller, same(lighter));
      expect(lighter.attempt.uri, _lightProfile.uri);
      expect(original.disposed, isTrue);

      rendered = 0;
      dropped = 0;
      for (var i = 0; i < 3; i++) {
        await check(lighter, 10);
      }
      expect(store.saved, isEmpty);
      expect(session.controller, same(lighter));
      for (var i = 0; i < 4; i++) {
        await check(lighter, 75);
      }
      expect(store.saved, {provider.camera.id: _lightProfile.pixels});
      session.dispose();
      await tester.pump();
    },
  );

  testWidgets('ongoing frame loss refreshes once without a lighter stream', (
    tester,
  ) async {
    final provider = _AdaptiveProvider()..offered = null;
    var time = 0;
    var rendered = 0;
    final session = CameraLiveSession(
      provider,
      createPlayback: provider.createPlayback,
      qualityStore: _QualityStore(),
      readFrameStats: (_) async => CameraLiveFrameStats(
        atMillis: time,
        rendered: rendered,
        dropped: 0,
        expectedFps: 15,
      ),
    );
    await session.resume();
    final original = provider.players.single;

    Future<void> check(_Player player, int frames) async {
      time += 5000;
      rendered += frames;
      player.advance();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    }

    await check(original, 75);
    await check(original, 75);
    await check(original, 10);
    await check(original, 10);
    expect(session.controller, same(original));
    expect(provider.requests, [(1280 * 720 - 1, original.attempt.uri)]);

    await check(original, 10);
    expect(original.disposed, isTrue);
    expect(provider.connects, 2);
    final replacement = provider.players.last;
    expect(session.controller, same(replacement));

    // The restart budget is not replenished by a still-broken stream.
    rendered = 0;
    for (var i = 0; i < 7; i++) {
      await check(replacement, 10);
    }
    expect(session.controller, same(replacement));
    expect(provider.connects, 2);

    // A later bad episode can recover after a minute of good playback.
    for (var i = 0; i < 12; i++) {
      await check(replacement, 75);
    }
    for (var i = 0; i < 3; i++) {
      await check(replacement, 10);
    }
    expect(replacement.disposed, isTrue);
    expect(provider.connects, 3);
    session.dispose();
    await tester.pump();
  });

  testWidgets(
    'a saved profile that cannot play falls back to the original URL',
    (tester) async {
      final provider = _AdaptiveProvider()..qualityOpens = false;
      final store = _QualityStore()
        ..saved[provider.camera.id] = _lightProfile.pixels;
      final session = CameraLiveSession(
        provider,
        createPlayback: provider.createPlayback,
        qualityStore: store,
      );
      await session.resume();
      final original = provider.players.single;
      expect(original.attempt.qualityPixels, isNull);
      expect(provider.requests, [(640 * 360, null)]);

      original.fail();
      await tester.pump(const Duration(seconds: 2));
      expect(provider.players, hasLength(2));
      expect(provider.requests, hasLength(1));

      session.dispose();
      await tester.pump();
    },
  );
}

Uint8List _motionFrame(bool moving) => Uint8List.fromList(
  List.generate(LiveMotionDetector.pixels, (i) => moving && i < 400 ? 140 : 60),
);

class _Provider extends Fake implements CameraProvider {
  _Provider({this.choices = 1});

  final int choices;
  final calls = <String>[];
  final players = <_Player>[];
  final preferred = <CameraPlaybackAttempt?>[];
  Object? connectionError;
  Completer<void>? pendingStart;
  int connects = 0;
  bool qualityOpens = true;

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
    CameraLiveQualityProfile? qualityProfile,
  }) {
    this.preferred.add(preferred);
    return _Playback(this, choices, qualityProfile);
  }
}

final _lightProfile = CameraLiveQualityProfile(
  Uri.parse('rtsp://192.168.1.9/lite'),
  640 * 360,
);

class _AdaptiveProvider extends _Provider implements CameraLiveQualitySource {
  CameraLiveQualityProfile? offered = _lightProfile;
  final requests = <(int, Uri?)>[];

  @override
  Future<CameraLiveQualityProfile?> findLiveQualityProfile({
    required int maxPixels,
    Uri? excluding,
  }) async {
    requests.add((maxPixels, excluding));
    return offered;
  }
}

class _QualityStore implements CameraLiveQualityStore {
  final saved = <String, int>{};

  @override
  Future<int?> readLiveQuality(String cameraId) async => saved[cameraId];

  @override
  Future<void> writeLiveQuality(String cameraId, int pixels) async {
    saved[cameraId] = pixels;
  }
}

class _Playback extends CameraLivePlayback {
  _Playback(this.provider, this._remaining, this._quality) : super(provider);
  final _Provider provider;
  int _remaining;
  CameraLiveQualityProfile? _quality;

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
    final quality = _quality;
    _quality = null;
    final CameraPlaybackAttempt attempt;
    if (quality != null && provider.qualityOpens) {
      attempt = CameraPlaybackAttempt(
        quality.uri,
        CameraRtspTransport.tcp,
        qualityPixels: quality.pixels,
      );
    } else {
      _remaining--;
      attempt = CameraPlaybackAttempt(
        Uri.parse('rtsp://192.168.1.9/profile-$_remaining'),
        CameraRtspTransport.tcp,
      );
    }
    final player = _Player(attempt);
    await player.setVolume(volume);
    openedAttempt = attempt;
    provider.players.add(player);
    return player;
  }
}

class _Player extends VideoPlayerController {
  _Player(this.attempt) : super.networkUrl(attempt.uri) {
    value = VideoPlayerValue(
      duration: const Duration(minutes: 2),
      size: attempt.qualityPixels == null
          ? const Size(1280, 720)
          : const Size(640, 360),
      isInitialized: true,
      isPlaying: true,
    );
  }

  final CameraPlaybackAttempt attempt;
  bool disposed = false;
  Duration? rawPosition;

  @override
  Future<Duration?> get position async => rawPosition ?? value.position;

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

  void buffer(bool buffering) {
    value = value.copyWith(isBuffering: buffering);
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
