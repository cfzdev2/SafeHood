import 'bridge_diagnostics.dart';

class BridgeStatus {
  final String id;
  final String name;
  final String status;
  final String platform;
  final String version;
  final int activeCameraCount;
  final DateTime? lastSeenAt;
  final DateTime? pairedAt;
  final bool isActive;
  final BridgeDiagnostics? diagnostics;

  const BridgeStatus({
    required this.id,
    required this.name,
    required this.status,
    required this.platform,
    required this.version,
    required this.activeCameraCount,
    required this.lastSeenAt,
    this.pairedAt,
    this.isActive = false,
    this.diagnostics,
  });

  bool isOnlineAt(DateTime now) {
    if (status != 'online') {
      return false;
    }

    final lastSeen = lastSeenAt;

    if (lastSeen == null) {
      return false;
    }

    final age = now.difference(lastSeen);

    return age <= const Duration(seconds: 90);
  }

  Duration? ageAt(DateTime now) {
    final lastSeen = lastSeenAt;

    if (lastSeen == null) {
      return null;
    }

    return now.difference(lastSeen);
  }

  bool get isSecurelyPaired {
    return pairedAt != null;
  }
}
