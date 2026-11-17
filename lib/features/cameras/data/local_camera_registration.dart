import '../domain/camera.dart';
import 'camera_discovery_service.dart';
import 'local_camera_connection.dart';
import 'local_camera_store.dart';

typedef SaveLocalCamera = Future<void> Function(LocalCameraRegistration camera);

/// An account camera and its separate, device-only playback settings.
class LocalCameraRegistration {
  const LocalCameraRegistration({
    required this.camera,
    required this.connection,
  });

  final Camera camera;
  final LocalCameraConnection connection;

  factory LocalCameraRegistration.fromPreview({
    required LocalCameraSource source,
    required String location,
    DetectedCamera? detected,
    Uri? onvifEndpoint,
    CameraLogin? login,
  }) {
    final uri = parseLocalRtsp(source.uri.toString());
    final name = source.name.trim();
    final locationName = location.trim();
    if (uri == null ||
        name.isEmpty ||
        name.length > 60 ||
        locationName.isEmpty ||
        locationName.length > 100) {
      throw ArgumentError('Nieprawidłowe dane kamery.');
    }
    final endpoint = onvifEndpoint == null
        ? null
        : parseManualOnvifUri(onvifEndpoint.toString());
    if (onvifEndpoint != null &&
        (endpoint == null ||
            endpoint.host != uri.host ||
            detected?.connectionType != CameraConnectionType.onvif ||
            detected?.ipAddress != uri.host)) {
      throw ArgumentError('Adres ONVIF nie należy do tej kamery.');
    }
    final isOnvif = endpoint != null;
    return LocalCameraRegistration(
      camera: Camera(
        id: '',
        name: name,
        locationName: locationName,
        brand:
            detected?.brand ??
            (source.reolinkUid == null ? 'Nieznany producent' : 'Reolink'),
        model: detected?.model ?? 'Nieznany model',
        ipAddress: uri.host,
        macAddress: detected?.macAddress,
        onvifServiceUrl: endpoint?.toString(),
        openPorts: {
          ...?detected?.openPorts,
          uri.hasPort ? uri.port : 554,
          if (endpoint != null) endpoint.port,
        },
        discoverySources: detected?.discoverySources ?? const {},
        isOnline: true,
        motionDetectionEnabled: isOnvif,
        hasSdCard: false,
        connectionType: isOnvif
            ? CameraConnectionType.onvif
            : CameraConnectionType.rtsp,
        monitoringMode: isOnvif
            ? CameraMonitoringMode.bridge
            : CameraMonitoringMode.app,
      ),
      connection: LocalCameraConnection(
        login: login,
        rtspUri: uri,
        reolinkUid: source.reolinkUid,
        rtspVerified: true,
      ),
    );
  }
}
