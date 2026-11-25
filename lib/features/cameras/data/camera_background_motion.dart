import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import 'camera_provider_factory.dart';
import 'local_camera_connection.dart';
import 'local_camera_auto_setup.dart';
import 'native_camera_profile.dart';
import 'xm_camera_service.dart';

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

/// Runs the phone receiver for the saved motion preference, without a separate
/// user setting. It is a local fallback; independent monitoring needs a receiver
/// that can reach the camera while this phone is unavailable.
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
  final _nativeInspector = NativeCameraInspector();

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
    const store = LocalCameraConnectionStore();
    final connection = (await store.read(camera.id)).forCamera(camera);
    final first = candidates.first;
    final login =
        connection.login ??
        localCameraStoredLogin(connection.playbackUri) ??
        const CameraLogin('admin', '');
    var profile = connection.nativeProfile;
    if (profile == null &&
        connection.rtspVerified &&
        first.host == camera.ipAddress) {
      profile = await _nativeInspector.inspect(
        cameraId: '${user.uid}/${camera.id}',
        host: first.host,
        username: login.username,
        password: login.password,
      );
      if (profile != null &&
          FirebaseAuth.instance.currentUser?.uid == user.uid) {
        await store.save(
          user.uid,
          camera.id,
          connection.withNativeProfile(profile),
        );
      }
    }
    if (FirebaseAuth.instance.currentUser?.uid != user.uid) {
      throw const CameraConnectionIssue('Zaloguj się ponownie.');
    }
    final notificationsAllowed = await _channel.invokeMethod<bool>('start', {
      'owner': user.uid,
      'cameraId': camera.id,
      'streams': candidates.map((uri) => uri.toString()).toList(),
      if (profile?.motionSupported == true)
        'nativeLogin': {'username': login.username, 'password': login.password},
      if (kDebugMode && _emulator) 'emulatorHost': _emulatorHost.trim(),
    });
    if (profile != null) {
      unawaited(
        XmCameraService.instance.ensureCamera(
          camera: camera,
          profile: profile,
          login: login,
        ),
      );
    }
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
