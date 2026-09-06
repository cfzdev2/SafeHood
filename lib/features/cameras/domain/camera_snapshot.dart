class CameraSnapshot {
  final String id;
  final String cameraId;

  final DateTime capturedAt;
  final Uri imageUri;

  /// Adresy zwracane przez chmurę
  /// producenta mogą być tymczasowe.
  final DateTime? expiresAt;

  const CameraSnapshot({
    required this.id,
    required this.cameraId,
    required this.capturedAt,
    required this.imageUri,
    this.expiresAt,
  });

  bool get hasExpired {
    final expiration = expiresAt;

    if (expiration == null) {
      return false;
    }

    return !expiration.isAfter(DateTime.now());
  }
}
