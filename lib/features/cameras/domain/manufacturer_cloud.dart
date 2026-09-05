import 'camera.dart';
import 'camera_provider.dart';

enum ManufacturerCloudAccountStatus {
  unavailable,
  disconnected,
  linking,
  connected,
  expired,
  error,
}

enum ManufacturerCloudLinkMethod { externalBrowser, deviceCode, nativeSdk }

class ManufacturerCloudAccountState {
  final CameraCloudProvider provider;
  final ManufacturerCloudAccountStatus status;

  // Bezpieczna nazwa konta wyświetlana
  // użytkownikowi, np. zamaskowany e-mail.
  final String? accountLabel;

  final String? errorMessage;
  final DateTime? updatedAt;

  const ManufacturerCloudAccountState({
    required this.provider,
    required this.status,
    this.accountLabel,
    this.errorMessage,
    this.updatedAt,
  });

  bool get isConnected => status == ManufacturerCloudAccountStatus.connected;
}

class ManufacturerCloudLinkSession {
  final String sessionId;

  final CameraCloudProvider provider;

  final ManufacturerCloudLinkMethod method;

  // Adres logowania producenta,
  // jeżeli integracja korzysta z OAuth.
  final Uri? authorizationUri;

  // Kod wyświetlany użytkownikowi,
  // jeżeli producent wykorzystuje
  // autoryzację urządzenia.
  final String? userCode;

  final DateTime? expiresAt;

  const ManufacturerCloudLinkSession({
    required this.sessionId,
    required this.provider,
    required this.method,
    this.authorizationUri,
    this.userCode,
    this.expiresAt,
  });
}

class ManufacturerCloudDevice {
  final String cloudDeviceId;

  final CameraCloudProvider provider;

  final String name;
  final String brand;
  final String model;

  final bool isOnline;
  final bool hasSdCard;

  final CameraCapabilities capabilities;

  const ManufacturerCloudDevice({
    required this.cloudDeviceId,
    required this.provider,
    required this.name,
    required this.brand,
    required this.model,
    required this.isOnline,
    required this.hasSdCard,
    required this.capabilities,
  });

  Camera toCamera({required String name, required String locationName}) {
    return Camera(
      id: cloudDeviceId,
      name: name,
      locationName: locationName,
      brand: brand,
      model: model,
      isOnline: isOnline,
      motionDetectionEnabled: true,
      hasSdCard: hasSdCard,
      connectionType: CameraConnectionType.manufacturerCloud,
      cloudProvider: provider,
      cloudDeviceId: cloudDeviceId,
      monitoringMode: CameraMonitoringMode.cloud,
      discoverySources: {'manufacturer-cloud', provider.name},
    );
  }
}

/// Wspólny interfejs komunikacji
/// z chmurą producenta.
///
/// Hasła i tokeny producenta nie mogą
/// być zapisywane w obiekcie Camera
/// ani bezpośrednio w Firestore.
abstract interface class ManufacturerCloudGateway {
  CameraCloudProvider get provider;

  Future<ManufacturerCloudAccountState> getAccountState();

  Future<ManufacturerCloudLinkSession> beginAccountLink();

  Future<List<ManufacturerCloudDevice>> getDevices();

  Future<void> disconnectAccount();
}
