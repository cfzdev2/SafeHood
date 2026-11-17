import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/camera_discovery_service.dart';
import 'package:safehood/features/cameras/data/local_camera_connection.dart';
import 'package:safehood/features/cameras/data/local_camera_registration.dart';
import 'package:safehood/features/cameras/data/local_camera_store.dart';
import 'package:safehood/features/cameras/domain/camera.dart';

void main() {
  const detected = DetectedCamera(
    deviceId: 'onvif-cam',
    displayName: 'Kamera',
    brand: 'NVT',
    model: 'IP camera',
    ipAddress: '192.168.1.9',
    connectionType: CameraConnectionType.onvif,
    openPorts: {8899},
  );
  final rtsp = Uri.parse('rtsp://192.168.1.9:554/live?password=secret&sub=1');
  final source = LocalCameraSource(name: ' Podjazd ', uri: rtsp);

  test('registers verified ONVIF without sharing the working RTSP URL', () {
    final endpoint = Uri.parse('http://192.168.1.9:8899/onvif/device_service');
    final result = LocalCameraRegistration.fromPreview(
      source: source,
      location: ' Dom ',
      detected: detected,
      onvifEndpoint: endpoint,
      login: const CameraLogin('admin', 'secret'),
    );
    final data = result.camera.toMap();
    expect(data['connectionType'], 'onvif');
    expect(data['monitoringMode'], 'bridge');
    expect(data['motionDetectionEnabled'], isTrue);
    expect(data['onvifServiceUrl'], endpoint.toString());
    expect(data['openPorts'], [554, 8899]);
    expect(data['name'], 'Podjazd');
    expect(data.toString(), isNot(contains('secret')));
    expect(data.toString(), isNot(contains('rtsp://')));
    expect(result.connection.rtspUri, rtsp);
    expect(result.connection.playbackUri, rtsp);
    expect(result.connection.login?.password, 'secret');
  });

  test('does not register ONVIF for a different camera', () {
    expect(
      () => LocalCameraRegistration.fromPreview(
        source: source,
        location: 'Dom',
        detected: detected,
        onvifEndpoint: Uri.parse('http://192.168.1.10:8899/onvif'),
      ),
      throwsArgumentError,
    );
  });
}
