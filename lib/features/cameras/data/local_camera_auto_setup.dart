import '../domain/camera.dart';
import 'camera_discovery_service.dart';
import 'local_camera_connection.dart';
import 'local_camera_store.dart';

String localCameraDisplayName(DetectedCamera device) {
  final address = device.ipAddress;
  if (device.displayName == 'Kamera ONVIF $address' ||
      device.displayName == 'Kamera RTSP $address' ||
      device.displayName == 'Kamera $address' ||
      device.displayName.trim().isEmpty) {
    return 'Kamera';
  }
  return device.displayName;
}

bool canTryLocalCamera(DetectedCamera device) {
  final address = device.ipAddress;
  return address != null &&
      parseLocalRtsp('rtsp://$address/')?.host == address &&
      (device.connectionType == CameraConnectionType.onvif ||
          device.connectionType == CameraConnectionType.rtsp);
}

Uri? localCameraOnvifEndpoint(DetectedCamera device) {
  if (!canTryLocalCamera(device) ||
      device.connectionType != CameraConnectionType.onvif) {
    return null;
  }
  final advertised = parseManualOnvifUri(device.onvifServiceUrl ?? '');
  if (advertised != null &&
      advertised.host == device.ipAddress &&
      advertised.scheme == 'http') {
    return advertised;
  }
  final port = const [
    8899,
    2020,
    80,
    8080,
    8000,
    9000,
  ].firstWhere(device.openPorts.contains, orElse: () => 80);
  return Uri(
    scheme: 'http',
    host: device.ipAddress,
    port: port,
    path: '/onvif/device_service',
  );
}

CameraLogin? localCameraStoredLogin(Uri? uri) {
  final parts = uri?.userInfo ?? '';
  final colon = parts.indexOf(':');
  if (colon <= 0) return null;
  try {
    final username = Uri.decodeComponent(parts.substring(0, colon));
    final password = Uri.decodeComponent(parts.substring(colon + 1));
    if (username.length > 128 || password.length > 128) return null;
    return CameraLogin(username, password);
  } on FormatException {
    return null;
  }
}

/// An open streaming port does not tell us the path. Try a bounded set on
/// the selected peer and let the player verify an actual video frame.
List<Uri> localCameraStreamCandidates(
  DetectedCamera device,
  CameraLogin? login,
) {
  if (!canTryLocalCamera(device)) return const [];
  final address = device.ipAddress!;
  final ports = {
    ...device.rtspPorts.where((port) => port >= 1 && port <= 65535),
    ...[554, 8554].where(device.openPorts.contains),
  }.take(2).toList();
  if (ports.isEmpty) ports.add(554);
  final brand = device.brand.toLowerCase();
  final paths = [
    if (brand.contains('hikvision')) '/Streaming/Channels/102',
    if (brand.contains('reolink')) '/Preview_01_sub',
    if (brand.contains('reolink')) '/h264Preview_01_sub',
    if (brand.contains('tapo')) '/stream2',
    '/live',
    '/stream1',
    '/',
  ];
  final candidates = <Uri>[];
  // If both common ports were detected, test both before spending time
  // guessing additional paths on either one.
  for (final path in paths) {
    for (final port in ports) {
      final uri = Uri(scheme: 'rtsp', host: address, port: port, path: path);
      candidates.add(applyCameraLogin(uri, login));
      if (candidates.length == 4) return candidates;
    }
  }
  return candidates;
}
