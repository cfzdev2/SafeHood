import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import 'dekco_safeark_camera_provider.dart';
import 'mock_camera_provider.dart';
import 'onvif_camera_provider.dart';
import 'unavailable_camera_provider.dart';

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
          reason:
              'Provider RTSP nie został '
              'jeszcze uruchomiony.',
        );

      case CameraConnectionType.manufacturerCloud:
        return _createManufacturerCloudProvider(camera);

      case CameraConnectionType.unknown:
        return UnavailableCameraProvider(
          camera: camera,
          reason:
              'SafeHood nie ustalił jeszcze '
              'sposobu połączenia.',
        );
    }
  }

  static CameraProvider _createManufacturerCloudProvider(Camera camera) {
    switch (camera.cloudProvider) {
      case CameraCloudProvider.safeArk:
        return DekcoSafeArkCameraProvider(camera: camera);

      case CameraCloudProvider.unknown:
      case null:
        return UnavailableCameraProvider(
          camera: camera,
          reason:
              'Nieobsługiwana chmura '
              'producenta kamery.',
        );
    }
  }
}
