import 'unavailable_camera_provider.dart';

class DekcoSafeArkCameraProvider extends UnavailableCameraProvider {
  DekcoSafeArkCameraProvider({required super.camera})
    : super(
        reason:
            'Kamera DEKCO SafeArk została rozpoznana, '
            'ale integracja oczekuje na oficjalne '
            'API lub SDK producenta.',
      );

  @override
  Future<void> connect() async {
    throw StateError(reason);
  }
}
