import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/camera.dart';
import 'native_camera_profile.dart';

class CameraLogin {
  const CameraLogin(this.username, this.password);

  final String username;
  final String password;
}

class LocalCameraConnection {
  const LocalCameraConnection({
    this.login,
    this.rtspUri,
    this.onvifUri,
    this.reolinkUid,
    this.rtspVerified = false,
    this.nativeProfile,
  });

  final CameraLogin? login;
  final Uri? rtspUri;
  final Uri? onvifUri;
  final String? reolinkUid;
  final bool rtspVerified;
  final NativeCameraProfile? nativeProfile;

  LocalCameraConnection withNativeProfile(NativeCameraProfile profile) =>
      LocalCameraConnection(
        login: login,
        rtspUri: rtspUri,
        onvifUri: onvifUri,
        reolinkUid: reolinkUid,
        rtspVerified: rtspVerified,
        nativeProfile: profile,
      );

  bool get isEmpty => login == null && rtspUri == null && onvifUri == null;

  Uri? get playbackUri {
    final uri = rtspUri;
    return uri == null || rtspVerified ? uri : applyCameraLogin(uri, login);
  }

  LocalCameraConnection forCamera(Camera camera) {
    final identity = camera.onvifDeviceId;
    final verifiedIdentity =
        identity != null &&
        RegExp(
          r'^(?:urn:)?(?:uuid:)?[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
          caseSensitive: false,
        ).hasMatch(identity);
    final saved = onvifUri;
    final current = parseManualOnvifUri(camera.onvifServiceUrl ?? '');
    if (!verifiedIdentity ||
        saved == null ||
        current == null ||
        current.host != camera.ipAddress ||
        saved.host == current.host) {
      return this;
    }
    return LocalCameraConnection(
      login: login,
      onvifUri: current,
      rtspUri: rtspUri?.host == saved.host
          ? rtspUri!.replace(host: current.host)
          : rtspUri,
      reolinkUid: reolinkUid,
      rtspVerified: rtspVerified,
      nativeProfile: nativeProfile,
    );
  }

  Camera cameraWithLocalEndpoint(Camera camera) {
    final endpoint = forCamera(camera).onvifUri;
    return endpoint == null
        ? camera
        : camera.copyWith(
            ipAddress: endpoint.host,
            onvifServiceUrl: endpoint.toString(),
          );
  }
}

abstract interface class CameraLiveQualityStore {
  Future<int?> readLiveQuality(String cameraId);
  Future<void> writeLiveQuality(String cameraId, int pixels);
}

/// Credentials and manually supplied RTSP URLs are never stored in Firestore.
class LocalCameraConnectionStore implements CameraLiveQualityStore {
  const LocalCameraConnectionStore();

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const _prefix = 'safehood.camera.connection.';

  String _key(String userId, String cameraId) => '$_prefix$userId.$cameraId';

  String _qualityKey(String userId, String cameraId) =>
      'safehood.camera.liveQuality.$userId.$cameraId';

  @override
  Future<int?> readLiveQuality(String cameraId) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return null;
    final raw = await _storage.read(key: _qualityKey(userId, cameraId));
    final pixels = int.tryParse(raw ?? '');
    return pixels != null && pixels > 0 ? pixels : null;
  }

  @override
  Future<void> writeLiveQuality(String cameraId, int pixels) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || pixels <= 0) return;
    await _storage.write(
      key: _qualityKey(userId, cameraId),
      value: pixels.toString(),
    );
  }

  Future<LocalCameraConnection> read(String cameraId) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return const LocalCameraConnection();

    final raw = await _storage.read(key: _key(userId, cameraId));
    if (raw == null) return const LocalCameraConnection();

    final data = jsonDecode(raw) as Map<String, dynamic>;
    final username = data['username'] as String?;
    final password = data['password'] as String?;
    final rtsp = data['rtsp'] as String?;
    final onvif = data['onvif'] as String?;
    final reolinkUid = data['reolinkUid'] as String?;
    return LocalCameraConnection(
      login: username == null || password == null
          ? null
          : CameraLogin(username, password),
      rtspUri: rtsp == null ? null : parseManualRtspUri(rtsp),
      onvifUri: onvif == null ? null : parseManualOnvifUri(onvif),
      rtspVerified: data['rtspVerified'] == true,
      nativeProfile: NativeCameraProfile.fromMap(data['nativeProfile']),
      reolinkUid:
          reolinkUid != null && RegExp(r'^[A-Z0-9]{16}$').hasMatch(reolinkUid)
          ? reolinkUid
          : null,
    );
  }

  Future<void> save(
    String userId,
    String cameraId,
    LocalCameraConnection connection,
  ) async {
    final key = _key(userId, cameraId);
    if (connection.isEmpty) return delete(userId, cameraId);
    await _storage.write(
      key: key,
      value: jsonEncode({
        'username': connection.login?.username,
        'password': connection.login?.password,
        'rtsp': connection.rtspUri?.toString(),
        'onvif': connection.onvifUri?.toString(),
        'reolinkUid': connection.reolinkUid,
        'rtspVerified': connection.rtspVerified,
        if (connection.nativeProfile != null)
          'nativeProfile': connection.nativeProfile!.toMap(),
      }),
    );
    await _forgetLiveQuality(userId, cameraId);
  }

  Future<void> delete(String userId, String cameraId) async {
    await _storage.delete(key: _key(userId, cameraId));
    await _forgetLiveQuality(userId, cameraId);
  }

  Future<void> _forgetLiveQuality(String userId, String cameraId) async {
    try {
      await _storage.delete(key: _qualityKey(userId, cameraId));
    } catch (_) {
      // The quality hint is optional; connection settings have been saved.
    }
  }
}

bool isCameraLanHost(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    return RegExp(
      r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+local$',
      caseSensitive: false,
    ).hasMatch(host);
  }
  final bytes = address.rawAddress;
  if (bytes.length == 4) {
    return bytes[0] == 10 ||
        bytes[0] == 127 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  if (bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255) {
    return isCameraLanHost(bytes.skip(12).join('.'));
  }
  return address.isLoopback || address.isLinkLocal || (bytes[0] & 0xfe) == 0xfc;
}

Uri? parseManualRtspUri(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.scheme != 'rtsp' ||
      !isCameraLanHost(uri.host) ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    return null;
  }
  return uri;
}

Uri? parseManualOnvifUri(String input) {
  final value = input.trim();
  final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      !isCameraLanHost(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    return null;
  }
  return uri.path.isEmpty || uri.path == '/'
      ? uri.replace(path: '/onvif/device_service')
      : uri;
}

Uri applyCameraLogin(Uri uri, CameraLogin? login) {
  if (login == null || uri.userInfo.isNotEmpty) return uri;
  final user = Uri.encodeComponent(login.username);
  final password = Uri.encodeComponent(login.password);
  return uri.replace(userInfo: '$user:$password');
}

Uri rtspStreamIdentity(Uri uri) => uri.replace(
  userInfo: '',
  port: uri.scheme == 'rtsp' && !uri.hasPort ? 554 : uri.port,
);

class CameraConnectionIssue implements Exception {
  const CameraConnectionIssue(this.message, {this.retryable = true});
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}
