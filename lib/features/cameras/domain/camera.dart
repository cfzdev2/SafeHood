enum CameraConnectionType { mock, rtsp, onvif, manufacturerCloud, unknown }

enum CameraCloudProvider { safeArk, unknown }

enum CameraMonitoringMode { app, bridge, cloud }

enum CameraMonitoringRuntimeStatus {
  unknown,
  connecting,
  online,
  reconnecting,
  offline,
}

class Camera {
  final String id;

  final String name;
  final String locationName;

  final String brand;
  final String model;

  final String? ipAddress;
  final String? macAddress;
  final String? onvifServiceUrl;
  final Set<int> openPorts;
  final Set<String> discoverySources;

  // Dostępność urządzenia/Media/LIVE.
  // Bridge Events nie powinien
  // zmieniać tego pola.
  final bool isOnline;

  // Określa, czy SafeHood ma
  // monitorować zdarzenia kamery.
  final bool motionDetectionEnabled;

  final bool hasSdCard;

  final CameraConnectionType connectionType;

  // Dostawca chmury producenta.
  // Dla DEKCO L5P/DL5P będzie to SafeArk.
  final CameraCloudProvider? cloudProvider;

  // Identyfikator urządzenia zwrócony
  // przez chmurę producenta.
  //
  // Nie zapisujemy tutaj hasła
  // ani tokenu dostępowego użytkownika.
  final String? cloudDeviceId;

  final CameraMonitoringMode monitoringMode;

  final String? bridgeId;

  // Stan sesji ONVIF Events,
  // niezależny od Media/RTSP/LIVE.
  final CameraMonitoringRuntimeStatus bridgeMonitoringStatus;

  const Camera({
    required this.id,
    required this.name,
    required this.locationName,
    required this.brand,
    required this.model,
    required this.isOnline,
    required this.motionDetectionEnabled,
    required this.hasSdCard,
    this.ipAddress,
    this.macAddress,
    this.onvifServiceUrl,
    this.openPorts = const {},
    this.discoverySources = const {},
    this.connectionType = CameraConnectionType.mock,
    this.cloudProvider,
    this.cloudDeviceId,
    this.monitoringMode = CameraMonitoringMode.bridge,
    this.bridgeId,
    this.bridgeMonitoringStatus = CameraMonitoringRuntimeStatus.unknown,
  });

  Camera copyWith({
    String? id,
    String? name,
    String? locationName,
    String? brand,
    String? model,
    String? ipAddress,
    String? macAddress,
    String? onvifServiceUrl,
    Set<int>? openPorts,
    Set<String>? discoverySources,
    bool? isOnline,
    bool? motionDetectionEnabled,
    bool? hasSdCard,
    CameraConnectionType? connectionType,
    CameraCloudProvider? cloudProvider,
    String? cloudDeviceId,
    CameraMonitoringMode? monitoringMode,
    String? bridgeId,
    CameraMonitoringRuntimeStatus? bridgeMonitoringStatus,
  }) {
    return Camera(
      id: id ?? this.id,
      name: name ?? this.name,
      locationName: locationName ?? this.locationName,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      ipAddress: ipAddress ?? this.ipAddress,
      macAddress: macAddress ?? this.macAddress,
      onvifServiceUrl: onvifServiceUrl ?? this.onvifServiceUrl,
      openPorts: openPorts ?? this.openPorts,
      discoverySources: discoverySources ?? this.discoverySources,
      isOnline: isOnline ?? this.isOnline,
      motionDetectionEnabled:
          motionDetectionEnabled ?? this.motionDetectionEnabled,
      hasSdCard: hasSdCard ?? this.hasSdCard,
      connectionType: connectionType ?? this.connectionType,
      cloudProvider: cloudProvider ?? this.cloudProvider,
      cloudDeviceId: cloudDeviceId ?? this.cloudDeviceId,
      monitoringMode: monitoringMode ?? this.monitoringMode,
      bridgeId: bridgeId ?? this.bridgeId,
      bridgeMonitoringStatus:
          bridgeMonitoringStatus ?? this.bridgeMonitoringStatus,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'locationName': locationName,
      'brand': brand,
      'model': model,
      'ipAddress': ipAddress,
      'macAddress': macAddress,
      'onvifServiceUrl': onvifServiceUrl,
      'openPorts': openPorts.toList()..sort(),
      'discoverySources': discoverySources.toList()..sort(),
      'isOnline': isOnline,
      'motionDetectionEnabled': motionDetectionEnabled,
      'hasSdCard': hasSdCard,
      'connectionType': connectionType.name,
      'cloudProvider': cloudProvider?.name,
      'cloudDeviceId': cloudDeviceId,
      'monitoringMode': monitoringMode.name,
      'bridgeId': bridgeId,

      // bridgeMonitoringStatus
      // zapisuje wyłącznie Bridge.
    };
  }

  factory Camera.fromMap(String id, Map<String, dynamic> map) {
    return Camera(
      id: id,
      name: map['name'] as String? ?? '',
      locationName: map['locationName'] as String? ?? '',
      brand: map['brand'] as String? ?? 'Nieznana',
      model: map['model'] as String? ?? 'Nieznany',
      ipAddress: _parseNullableString(map['ipAddress']),
      macAddress: _parseNullableString(map['macAddress']),
      onvifServiceUrl: _parseNullableString(map['onvifServiceUrl']),
      openPorts: _parsePorts(map['openPorts']),
      discoverySources: _parseSources(map['discoverySources']),
      isOnline: map['isOnline'] as bool? ?? false,
      motionDetectionEnabled: map['motionDetectionEnabled'] as bool? ?? true,
      hasSdCard: map['hasSdCard'] as bool? ?? false,
      connectionType: _parseConnectionType(map['connectionType'] as String?),
      cloudProvider: _parseCloudProvider(map['cloudProvider']),
      cloudDeviceId: _parseNullableString(map['cloudDeviceId']),
      monitoringMode: _parseMonitoringMode(map['monitoringMode'] as String?),
      bridgeId: _parseNullableString(map['bridgeId']),
      bridgeMonitoringStatus: _parseMonitoringStatus(
        map['bridgeMonitoringStatus'] as String?,
      ),
    );
  }

  static String? _parseNullableString(dynamic value) {
    if (value is! String) {
      return null;
    }

    final normalized = value.trim();

    if (normalized.isEmpty) {
      return null;
    }

    return normalized;
  }

  static Set<int> _parsePorts(dynamic value) {
    if (value is! List) {
      return {};
    }

    return value.whereType<num>().map((port) => port.toInt()).toSet();
  }

  static Set<String> _parseSources(dynamic value) {
    if (value is! List) {
      return {};
    }

    return value
        .whereType<String>()
        .where((source) => source.trim().isNotEmpty)
        .toSet();
  }

  static CameraConnectionType _parseConnectionType(String? value) {
    if (value == null || value.isEmpty) {
      return CameraConnectionType.mock;
    }

    return CameraConnectionType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => CameraConnectionType.unknown,
    );
  }

  static CameraCloudProvider? _parseCloudProvider(dynamic value) {
    if (value is! String) {
      return null;
    }

    final normalized = value.trim();

    if (normalized.isEmpty) {
      return null;
    }

    return CameraCloudProvider.values.firstWhere(
      (provider) => provider.name == normalized,
      orElse: () => CameraCloudProvider.unknown,
    );
  }

  static CameraMonitoringMode _parseMonitoringMode(String? value) {
    if (value == null || value.isEmpty) {
      return CameraMonitoringMode.bridge;
    }

    return CameraMonitoringMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => CameraMonitoringMode.bridge,
    );
  }

  static CameraMonitoringRuntimeStatus _parseMonitoringStatus(String? value) {
    if (value == null || value.isEmpty) {
      return CameraMonitoringRuntimeStatus.unknown;
    }

    return CameraMonitoringRuntimeStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => CameraMonitoringRuntimeStatus.unknown,
    );
  }
}
