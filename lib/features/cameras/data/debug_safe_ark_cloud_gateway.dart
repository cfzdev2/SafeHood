import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import '../domain/manufacturer_cloud.dart';

class DebugSafeArkCloudGateway implements ManufacturerCloudGateway {
  const DebugSafeArkCloudGateway();

  @override
  CameraCloudProvider get provider => CameraCloudProvider.safeArk;

  @override
  Future<ManufacturerCloudAccountState> getAccountState() async {
    return ManufacturerCloudAccountState(
      provider: provider,
      status: ManufacturerCloudAccountStatus.connected,
      accountLabel: 'Testowe konto SafeArk',
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<ManufacturerCloudLinkSession> beginAccountLink() async {
    return ManufacturerCloudLinkSession(
      sessionId: 'debug-safeark-session',
      provider: provider,
      method: ManufacturerCloudLinkMethod.nativeSdk,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<List<ManufacturerCloudDevice>> getDevices() async {
    return [
      ManufacturerCloudDevice(
        cloudDeviceId: 'debug-dekco-l5p-1',
        provider: provider,
        name: 'DEKCO Podjazd',
        brand: 'DEKCO',
        model: 'Floodlight Camera Pro L5P/DL5P',
        isOnline: true,
        hasSdCard: true,
        capabilities: const CameraCapabilities(
          supportsLive: true,
          supportsAudio: true,
          supportsTalk: true,
          supportsMotionDetection: true,
          supportsPersonDetection: true,
          supportsRecordings: true,
          supportsSnapshot: true,
          supportsPtz: true,
          supportsFloodlight: true,
          supportsSiren: true,
        ),
      ),
    ];
  }

  @override
  Future<void> disconnectAccount() async {
    // Symulator nie zapisuje konta
    // ani żadnych danych logowania.
  }
}
