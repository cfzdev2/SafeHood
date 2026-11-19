import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../domain/camera_provider.dart';
import 'local_camera_connection.dart';

enum CameraRtspTransport { platformDefault, tcp }

class CameraPlaybackAttempt {
  const CameraPlaybackAttempt(this.uri, this.transport);
  final Uri uri;
  final CameraRtspTransport transport;
}

List<CameraPlaybackAttempt> cameraPlaybackAttempts(
  Iterable<Uri> streams, {
  required bool android,
  CameraPlaybackAttempt? preferred,
}) {
  final candidates = streams.toSet().take(2);
  final attempts = [
    for (final uri in candidates)
      CameraPlaybackAttempt(
        uri,
        android && uri.scheme == 'rtsp'
            ? CameraRtspTransport.tcp
            : CameraRtspTransport.platformDefault,
      ),
    if (android)
      for (final uri in candidates.where((uri) => uri.scheme == 'rtsp'))
        CameraPlaybackAttempt(uri, CameraRtspTransport.platformDefault),
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

class CameraLivePlayback {
  CameraLivePlayback(
    CameraProvider provider, {
    CameraPlaybackAttempt? preferred,
  }) : _attempts = cameraPlaybackAttempts(
         [
           if (provider.liveStreamUri case final Uri uri) uri,
           if (provider is CameraLiveStreamAlternatives)
             ...(provider as CameraLiveStreamAlternatives)
                 .liveStreamAlternatives,
         ],
         android: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
         preferred: preferred,
       );

  final List<CameraPlaybackAttempt> _attempts;
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
      final controller = VideoPlayerController.networkUrl(
        attempt.uri,
        httpHeaders: attempt.transport == CameraRtspTransport.tcp
            ? const {'X-SafeHood-Rtsp-Transport': 'tcp'}
            : const {},
      );
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
