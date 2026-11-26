import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../domain/camera_provider.dart';
import 'local_camera_connection.dart';

enum CameraRtspTransport { platformDefault, tcp }

class CameraPlaybackAttempt {
  const CameraPlaybackAttempt(
    this.uri,
    this.transport, {
    this.qualityPixels,
    this.softwareDecoder = false,
  });
  final Uri uri;
  final CameraRtspTransport transport;
  final int? qualityPixels;
  final bool softwareDecoder;
}

class CameraLiveFrameStats {
  const CameraLiveFrameStats({
    required this.atMillis,
    required this.rendered,
    required this.dropped,
    this.expectedFps,
    this.corruptImage,
  });

  final int atMillis;
  final int rendered;
  final int dropped;
  final double? expectedFps;
  final bool? corruptImage;
}

List<CameraPlaybackAttempt> cameraPlaybackAttempts(
  Iterable<Uri> streams, {
  required bool android,
  CameraPlaybackAttempt? preferred,
  CameraLiveQualityProfile? qualityProfile,
}) {
  List<CameraPlaybackAttempt> group(Iterable<Uri> candidates, {int? pixels}) {
    final attempts = [
      for (final uri in candidates)
        CameraPlaybackAttempt(
          uri,
          android && uri.scheme == 'rtsp'
              ? CameraRtspTransport.tcp
              : CameraRtspTransport.platformDefault,
          qualityPixels: pixels,
          softwareDecoder: preferred?.softwareDecoder ?? false,
        ),
      if (android)
        for (final uri in candidates.where((uri) => uri.scheme == 'rtsp'))
          CameraPlaybackAttempt(
            uri,
            CameraRtspTransport.platformDefault,
            qualityPixels: pixels,
            softwareDecoder: preferred?.softwareDecoder ?? false,
          ),
    ];
    if (preferred != null) {
      final index = attempts.indexWhere(
        (item) =>
            item.uri == preferred.uri && item.transport == preferred.transport,
      );
      if (index > 0) {
        final match = attempts.removeAt(index);
        attempts.insert(0, match);
      }
    }
    return attempts;
  }

  return [
    if (qualityProfile != null)
      ...group([qualityProfile.uri], pixels: qualityProfile.pixels),
    ...group(
      streams.toSet().take(2).where((uri) => uri != qualityProfile?.uri),
    ),
  ];
}

class CameraLivePlayback {
  CameraLivePlayback(
    CameraProvider provider, {
    CameraPlaybackAttempt? preferred,
    CameraLiveQualityProfile? qualityProfile,
  }) : _canSample =
           !kIsWeb &&
           defaultTargetPlatform == TargetPlatform.android &&
           provider.camera.usesLocalConnection,
       _attempts = cameraPlaybackAttempts(
         [
           if (provider.liveStreamUri case final Uri uri) uri,
           if (provider is CameraLiveStreamAlternatives)
             ...(provider as CameraLiveStreamAlternatives)
                 .liveStreamAlternatives,
         ],
         android: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
         preferred: preferred,
         qualityProfile: qualityProfile,
       );

  final List<CameraPlaybackAttempt> _attempts;
  final bool _canSample;
  static const _frameChannel = MethodChannel('safehood/camera_frame');
  static int _nextFrameSession = 0;
  static final _frameSessions = Expando<String>();
  static String? frameSessionFor(VideoPlayerController player) =>
      _frameSessions[player];

  static Future<Uint8List?> readShareFrame(VideoPlayerController player) {
    final session = frameSessionFor(player);
    final size = player.value.size;
    if (session == null || size.isEmpty || !size.isFinite) {
      return Future.value(null);
    }
    final scale = math.min(1.0, 320.0 / math.max(size.width, size.height));
    return _frameChannel.invokeMethod<Uint8List>('snapshot', {
      'session': session,
      'width': math.max(1, (size.width * scale).round()),
      'height': math.max(1, (size.height * scale).round()),
    });
  }

  static Future<CameraLiveFrameStats?> readFrameStats(
    VideoPlayerController player,
  ) async {
    final session = frameSessionFor(player);
    if (session == null) return null;
    final stats = await _frameChannel.invokeMapMethod<String, num>(
      'frameStats',
      {'session': session},
    );
    if (stats == null ||
        stats['atMillis'] is! int ||
        stats['rendered'] is! int ||
        stats['dropped'] is! int) {
      return null;
    }
    final expectedFps = stats['expectedFps']?.toDouble();
    return CameraLiveFrameStats(
      atMillis: stats['atMillis'] as int,
      rendered: stats['rendered'] as int,
      dropped: stats['dropped'] as int,
      expectedFps: expectedFps != null && expectedFps > 0 && expectedFps <= 240
          ? expectedFps
          : null,
      corruptImage: stats.containsKey('corrupt') ? stats['corrupt'] == 1 : null,
    );
  }

  int _next = 0;
  CameraPlaybackAttempt? _openedAttempt;
  bool get hasNext => _next < _attempts.length;
  CameraPlaybackAttempt? get openedAttempt => _openedAttempt;

  Future<VideoPlayerController?> openNext({
    required bool Function() isActive,
    required double volume,
  }) async {
    while (hasNext && isActive()) {
      final attempt = _attempts[_next++];
      final frameSession = _canSample && attempt.uri.scheme == 'rtsp'
          ? (++_nextFrameSession).toString()
          : null;
      final controller = VideoPlayerController.networkUrl(
        attempt.uri,
        httpHeaders: {
          if (attempt.transport == CameraRtspTransport.tcp)
            'X-SafeHood-Rtsp-Transport': 'tcp',
          'X-SafeHood-Frame-Session': ?frameSession,
          if (attempt.uri.scheme == 'rtsp' && attempt.softwareDecoder)
            'X-SafeHood-Decoder': 'software',
        },
      );
      if (frameSession != null) _frameSessions[controller] = frameSession;
      var keep = false;
      try {
        await controller.initialize().timeout(const Duration(seconds: 9));
        if (!isActive()) return null;
        if (controller.value.hasError ||
            (attempt.uri.scheme == 'rtsp' && controller.value.size.isEmpty)) {
          throw const CameraConnectionIssue(
            'Strumień RTSP nie zawiera obrazu.',
          );
        }
        if (attempt.qualityPixels case final int pixels) {
          final size = controller.value.size;
          if (!size.isFinite || size.width * size.height > pixels) {
            throw const CameraConnectionIssue(
              'Kamera nie udostępniła wybranego rozmiaru obrazu.',
            );
          }
        }
        await controller.setVolume(volume).timeout(const Duration(seconds: 3));
        if (!isActive()) return null;
        await controller.play().timeout(const Duration(seconds: 3));
        if (!isActive()) return null;
        if (controller.value.hasError) {
          throw const CameraConnectionIssue('Odtwarzacz odrzucił strumień.');
        }
        keep = true;
        _openedAttempt = attempt;
        return controller;
      } catch (error) {
        // Playback exceptions can contain a complete RTSP URL with login.
        debugPrint(
          'CAMERA LIVE: próba $_next/${_attempts.length} '
          '(${attempt.transport.name}) — ${error.runtimeType}',
        );
      } finally {
        if (!keep) {
          try {
            await controller.dispose().timeout(const Duration(seconds: 3));
          } catch (_) {
            debugPrint(
              'CAMERA LIVE: zamknięcie nieudanej sesji nie zakończyło się w czasie.',
            );
          }
        }
      }
    }
    if (!isActive()) return null;
    throw CameraConnectionIssue(
      _attempts.isEmpty
          ? 'Kamera nie udostępniła adresu obrazu.'
          : 'Nie udało się odtworzyć obrazu z kamery. Sprawdź profil H.264 lub wpisz inny adres RTSP.',
      retryable: _attempts.isNotEmpty,
    );
  }
}
