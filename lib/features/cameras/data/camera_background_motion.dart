import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import 'camera_provider_factory.dart';
import 'local_camera_connection.dart';

class CameraBackgroundMotionStatus {
  const CameraBackgroundMotionStatus({this.cameraId, this.phase = 'off'});

  final String? cameraId;
  final String phase;

  static CameraBackgroundMotionStatus fromMap(Map<Object?, Object?>? map) =>
      CameraBackgroundMotionStatus(
        cameraId: map?['cameraId'] as String?,
        phase: map?['phase'] as String? ?? 'off',
      );
}

/// Configures the Android service from an explicit tap while SafeHood is open.
/// The service keeps receiving samples even when the Flutter engine is gone.
class CameraBackgroundMotion {
  CameraBackgroundMotion._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'statusChanged') {
        status.value = CameraBackgroundMotionStatus.fromMap(
          call.arguments as Map<Object?, Object?>?,
        );
      }
    });
    unawaited(refresh());
  }

  static final instance = CameraBackgroundMotion._();
  static const _channel = MethodChannel('safehood/background_motion');
  static const _emulator = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
  static const _emulatorHost = String.fromEnvironment('FIREBASE_EMULATOR_HOST');
  static int _nextPreview = 0;

  final status = ValueNotifier(const CameraBackgroundMotionStatus());

  static bool supported(Camera camera) =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      camera.usesLocalConnection;

  Future<void> refresh() async {
    try {
      status.value = CameraBackgroundMotionStatus.fromMap(
        await _channel.invokeMapMethod<Object?, Object?>('status'),
      );
    } on PlatformException {
      status.value = const CameraBackgroundMotionStatus();
    } on MissingPluginException {
      status.value = const CameraBackgroundMotionStatus();
    }
  }

  Future<bool> start(Camera camera) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !user.emailVerified) {
      throw const CameraConnectionIssue(
        'Zaloguj się i zweryfikuj adres e-mail.',
      );
    }
    final provider = CameraProviderFactory.create(camera);
    final streams = <Uri>{};
    try {
      await provider.connect().timeout(const Duration(seconds: 12));
      if (provider is CameraLiveQualitySource) {
        try {
          final low = await (provider as CameraLiveQualitySource)
              .findLiveQualityProfile(maxPixels: 640 * 480)
              .timeout(const Duration(seconds: 3));
          if (low?.uri case final uri?) streams.add(uri);
        } catch (_) {
          // A camera may have only its main stream. It remains a candidate.
        }
      }
      if (provider.liveStreamUri case final uri?) streams.add(uri);
      if (provider is CameraLiveStreamAlternatives) {
        streams.addAll(
          (provider as CameraLiveStreamAlternatives).liveStreamAlternatives,
        );
      }
    } finally {
      await provider.dispose().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    final candidates = streams.where((uri) => uri.scheme == 'rtsp').take(3);
    if (candidates.isEmpty) {
      throw const CameraConnectionIssue(
        'Nie znaleziono lokalnego obrazu z kamery.',
      );
    }
    if (FirebaseAuth.instance.currentUser?.uid != user.uid) {
      throw const CameraConnectionIssue('Zaloguj się ponownie.');
    }
    final notificationsAllowed = await _channel.invokeMethod<bool>('start', {
      'owner': user.uid,
      'cameraId': camera.id,
      'streams': candidates.map((uri) => uri.toString()).toList(),
      if (kDebugMode && _emulator) 'emulatorHost': _emulatorHost.trim(),
    });
    return notificationsAllowed == true;
  }

  Future<void> stop(String cameraId) =>
      _channel.invokeMethod<void>('stop', {'cameraId': cameraId});

  static int? claimPreview(Camera camera) {
    if (!supported(camera)) return null;
    final lease = ++_nextPreview;
    unawaited(_setPreview(lease, camera.id));
    return lease;
  }

  static void releasePreview(int? lease) {
    if (lease != null) unawaited(_setPreview(lease, null));
  }

  static Future<void> _setPreview(int lease, String? cameraId) async {
    try {
      await _channel.invokeMethod<void>('preview', {
        'lease': lease,
        'cameraId': ?cameraId,
      });
    } on PlatformException {
      // The preview still works when monitoring is unavailable.
    } on MissingPluginException {
      // Desktop and test players have no Android service.
    }
  }
}
