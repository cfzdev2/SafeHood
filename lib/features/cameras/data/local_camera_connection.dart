import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/camera.dart';

class CameraLogin {
  const CameraLogin(this.username, this.password);

  final String username;
  final String password;
}

class LocalCameraConnection {
  const LocalCameraConnection({this.login, this.rtspUri, this.onvifUri});

  final CameraLogin? login;
  final Uri? rtspUri;
  final Uri? onvifUri;

  bool get isEmpty => login == null && rtspUri == null && onvifUri == null;

  Camera cameraWithLocalEndpoint(Camera camera) {
    final endpoint = onvifUri;
    return endpoint == null
        ? camera
        : camera.copyWith(
            ipAddress: endpoint.host,
            onvifServiceUrl: endpoint.toString(),
          );
  }
}

/// Credentials and manually supplied RTSP URLs are never stored in Firestore.
class LocalCameraConnectionStore {
  const LocalCameraConnectionStore();

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const _prefix = 'safehood.camera.connection.';

  String _key(String userId, String cameraId) => '$_prefix$userId.$cameraId';

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
    return LocalCameraConnection(
      login: username == null || password == null
          ? null
          : CameraLogin(username, password),
      rtspUri: rtsp == null ? null : parseManualRtspUri(rtsp),
      onvifUri: onvif == null ? null : parseManualOnvifUri(onvif),
    );
  }

  Future<void> save(
    String userId,
    String cameraId,
    LocalCameraConnection connection,
  ) {
    final key = _key(userId, cameraId);
    if (connection.isEmpty) return _storage.delete(key: key);
    return _storage.write(
      key: key,
      value: jsonEncode({
        'username': connection.login?.username,
        'password': connection.login?.password,
        'rtsp': connection.rtspUri?.toString(),
        'onvif': connection.onvifUri?.toString(),
      }),
    );
  }

  Future<void> delete(String userId, String cameraId) =>
      _storage.delete(key: _key(userId, cameraId));
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

class CameraConnectionIssue implements Exception {
  const CameraConnectionIssue(this.message);
  final String message;

  @override
  String toString() => message;
}
