import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/camera.dart';
import 'local_camera_connection.dart';
import 'native_camera_profile.dart';

typedef XmBackendCall =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, Object?> arguments,
    );

/// One SafeHood account owns a private, automatically provisioned camera-service
/// account. No second app, protocol selector, or extra monitoring switch.
class XmCameraService {
  XmCameraService({
    XmBackendCall? backend,
    MethodChannel? channel,
    String? Function()? currentOwner,
    bool Function()? supported,
  }) : _backend = backend ?? _callBackend,
       _channel = channel ?? const MethodChannel('safehood/xm_camera'),
       _owner = currentOwner ?? (() => FirebaseAuth.instance.currentUser?.uid),
       _supported =
           supported ??
           (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static final instance = XmCameraService();
  final XmBackendCall _backend;
  final MethodChannel _channel;
  final String? Function() _owner;
  final bool Function() _supported;
  final _jobs = <String, Future<bool>>{};
  Future<void> _tail = Future.value();

  static Future<Map<String, dynamic>> _callBackend(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final result =
        await FirebaseFunctions.instanceFor(region: 'europe-central2')
            .httpsCallable(
              method,
              options: HttpsCallableOptions(
                timeout: const Duration(seconds: 15),
              ),
            )
            .call<Map<String, dynamic>>(arguments);
    return result.data;
  }

  Future<bool> ensureCamera({
    required Camera camera,
    required NativeCameraProfile profile,
    required CameraLogin login,
  }) {
    final owner = _owner();
    if (!_supported() ||
        owner == null ||
        profile.protocol != 'dvrip' ||
        profile.serialNumber == null ||
        !profile.motionSupported) {
      return Future.value(false);
    }
    final key = '$owner/${camera.id}';
    return _jobs.putIfAbsent(key, () {
      // FunSDK's account and push managers are process-wide singletons.
      final job = _tail.then((_) => _connect(owner, camera, profile, login));
      _tail = job.then<void>((_) {});
      return job;
    });
  }

  Future<bool> _connect(
    String owner,
    Camera camera,
    NativeCameraProfile profile,
    CameraLogin login,
  ) async {
    void requireOwner() {
      if (_owner() != owner) throw StateError('Account changed');
    }

    Future<Map<String, dynamic>> backend(
      String method,
      Map<String, Object?> data,
    ) async {
      requireOwner();
      final reply = await _backend(method, data);
      requireOwner();
      return reply;
    }

    Future<void> sdk(String method, Map<String, Object?> data) async {
      requireOwner();
      final reply = await _channel
          .invokeMapMethod<String, dynamic>(method, {'owner': owner, ...data})
          .timeout(const Duration(seconds: 35));
      requireOwner();
      if (reply?['ok'] != true) throw StateError('Camera service unavailable');
    }

    try {
      requireOwner();
      final available = await _channel.invokeMapMethod<String, dynamic>(
        'available',
      );
      requireOwner();
      if (available?['available'] != true) return false;
      final account = await backend('provisionXmCameraAccount', {});
      await sdk('ensureAccount', {
        'username': account['username'],
        'password': account['password'],
        'needsRegistration': account['needsRegistration'] == true,
      });
      await backend('confirmXmCameraAccount', {});
      final route = await backend('createXmAlarmRoute', {});
      final routeId = route['routeId'];
      final callbackUrl = route['callbackUrl'];
      final callback = callbackUrl is String ? Uri.tryParse(callbackUrl) : null;
      if (routeId is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(routeId) ||
          callback == null ||
          callback.scheme != 'https' ||
          callback.host.isEmpty ||
          callback.userInfo.isNotEmpty ||
          callback.hasFragment) {
        return false;
      }
      await backend('bindXmCamera', {
        'routeId': routeId,
        'cameraId': camera.id,
        'serialNumber': profile.serialNumber,
      });
      await sdk('subscribe', {
        'serialNumber': profile.serialNumber,
        'deviceUsername': login.username,
        'devicePassword': login.password,
        'routeId': routeId,
        'callbackUrl': callback.toString(),
      });
      await backend('confirmXmAlarmSubscription', {
        'routeId': routeId,
        'cameraId': camera.id,
      });
      return true;
    } catch (_) {
      // Local playback and phone monitoring remain usable. Never print SDK
      // credentials, callback URLs, or exception messages containing them.
      return false;
    }
  }
}
