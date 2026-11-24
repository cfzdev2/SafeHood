import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/data/local_camera_connection.dart';

void main() {
  test(
    'a verified same-device address rebases local endpoints and retains credentials',
    () {
      const camera = Camera(
        id: 'robot',
        name: 'Robot',
        locationName: '',
        brand: '',
        model: '',
        isOnline: false,
        motionDetectionEnabled: true,
        hasSdCard: false,
        ipAddress: '192.168.1.12',
        onvifServiceUrl: 'http://192.168.1.12:8899/onvif/device_service',
        onvifDeviceId: 'urn:uuid:12345678-1234-1234-1234-123456789abc',
      );
      final saved = LocalCameraConnection(
        login: const CameraLogin('admin', 'test'),
        onvifUri: Uri.parse('http://192.168.1.9:8899/onvif/device_service'),
        rtspUri: Uri.parse('rtsp://192.168.1.9:554/live'),
        rtspVerified: true,
      );
      final recovered = saved.forCamera(
        Camera.fromMap(camera.id, camera.toMap()),
      );
      expect(recovered.rtspUri?.host, '192.168.1.12');
      expect(recovered.login?.password, 'test');
      expect(recovered.rtspUri?.path, '/live');
      expect(
        recovered.cameraWithLocalEndpoint(camera).ipAddress,
        '192.168.1.12',
      );
      expect(
        saved.forCamera(camera.copyWith(onvifDeviceId: 'onvif-192.168.1.9')),
        same(saved),
      );
    },
  );
}
