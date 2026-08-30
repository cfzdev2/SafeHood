import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import 'mock_camera_provider.dart';
import 'unavailable_camera_provider.dart';
import 'onvif_camera_provider.dart';

class CameraProviderFactory {
  const CameraProviderFactory._();

  static CameraProvider create(Camera camera) {
    switch (camera.connectionType) {
      case CameraConnectionType.mock:
        return MockCameraProvider(camera: camera);

      case CameraConnectionType.onvif:
        return OnvifCameraProvider(camera: camera);

      case CameraConnectionType.rtsp:
        return UnavailableCameraProvider(
          camera: camera,
          reason: 'Provider RTSP nie został jeszcze uruchomiony.',
        );

      case CameraConnectionType.manufacturerCloud:
        return UnavailableCameraProvider(
          camera: camera,
          reason: 'Integracja producenta nie została jeszcze uruchomiona.',
        );

      case CameraConnectionType.unknown:
        return UnavailableCameraProvider(
          camera: camera,
          reason: 'SafeHood nie ustalił jeszcze sposobu połączenia.',
        );
    }
  }
}
