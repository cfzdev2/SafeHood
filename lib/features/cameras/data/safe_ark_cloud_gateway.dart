import '../domain/camera.dart';
import '../domain/manufacturer_cloud.dart';

class SafeArkCloudGateway implements ManufacturerCloudGateway {
  static const unavailableReason =
      'Integracja SafeArk oczekuje na '
      'oficjalne API lub SDK producenta.';

  const SafeArkCloudGateway();

  @override
  CameraCloudProvider get provider => CameraCloudProvider.safeArk;

  @override
  Future<ManufacturerCloudAccountState> getAccountState() async {
    return ManufacturerCloudAccountState(
      provider: provider,
      status: ManufacturerCloudAccountStatus.unavailable,
      errorMessage: unavailableReason,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<ManufacturerCloudLinkSession> beginAccountLink() async {
    throw StateError(unavailableReason);
  }

  @override
  Future<List<ManufacturerCloudDevice>> getDevices() async {
    throw StateError(unavailableReason);
  }

  @override
  Future<void> disconnectAccount() async {
    // Konto nie jest jeszcze połączone,
    // więc nie ma danych do usunięcia.
  }
}
