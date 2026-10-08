import 'package:cloud_firestore/cloud_firestore.dart';

enum CameraEventType {
  motion,
  person,
  vehicle,
  sound,
  tamper,
  cameraOffline,
  cameraOnline,
  unknown,
}

enum CameraEventStatus { newEvent, viewed, dismissed, escalated }

class CameraEvent {
  final String id;

  final String cameraId;
  final String ownerId;

  final CameraEventType type;
  final CameraEventStatus status;

  /// Pierwszy moment wykrycia zdarzenia.
  final DateTime occurredAt;

  /// Ostatni moment wykrycia w obrębie
  /// tego samego zagregowanego zdarzenia.
  final DateTime lastOccurredAt;

  /// Ile pojedynczych sygnałów zostało
  /// połączonych w to zdarzenie.
  final int occurrenceCount;

  /// Źródło zdarzenia, np.:
  /// fake
  /// onvif
  /// reolink
  /// hikvision
  /// local_ai
  final String source;

  /// Pewność detekcji 0.0 - 1.0.
  /// Nie każda kamera ją udostępnia.
  final double? confidence;

  final String? snapshotUrl;
  final String? snapshotPath;
  final String? clipUrl;
  final String? clipPath;
  final int? clipDurationMillis;
  final int? clipPrebufferMillis;

  /// Jeśli użytkownik utworzył zgłoszenie
  /// na podstawie tego wykrycia.
  final String? incidentId;

  final DateTime createdAt;
  final DateTime updatedAt;

  const CameraEvent({
    required this.id,
    required this.cameraId,
    required this.ownerId,
    required this.type,
    required this.status,
    required this.occurredAt,
    required this.lastOccurredAt,
    required this.occurrenceCount,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.confidence,
    this.snapshotUrl,
    this.snapshotPath,
    this.clipUrl,
    this.clipPath,
    this.clipDurationMillis,
    this.clipPrebufferMillis,
    this.incidentId,
  });

  bool get isNew => status == CameraEventStatus.newEvent;

  bool get isViewed => status == CameraEventStatus.viewed;

  bool get isDismissed => status == CameraEventStatus.dismissed;

  bool get isEscalated => status == CameraEventStatus.escalated;

  bool get hasSnapshot =>
      (snapshotPath?.trim().isNotEmpty ?? false) ||
      (snapshotUrl?.trim().isNotEmpty ?? false);

  String? get privateClipPath {
    final path = clipPath?.trim();
    if (ownerId.isEmpty ||
        id.isEmpty ||
        ownerId.contains('/') ||
        id.contains('/')) {
      return null;
    }
    final expected = 'users/$ownerId/cameraEvents/$id/clip.mp4';
    return path == expected ? path : null;
  }

  bool get hasClip =>
      privateClipPath != null || (clipUrl?.trim().isNotEmpty ?? false);

  bool get hasIncident => incidentId != null && incidentId!.trim().isNotEmpty;

  Map<String, dynamic> toMap() {
    return {
      'cameraId': cameraId,
      'ownerId': ownerId,
      'type': _typeToString(type),
      'status': _statusToString(status),
      'occurredAt': Timestamp.fromDate(occurredAt),
      'lastOccurredAt': Timestamp.fromDate(lastOccurredAt),
      'occurrenceCount': occurrenceCount,
      'source': source,
      'confidence': confidence,
      'snapshotUrl': snapshotUrl,
      'snapshotPath': snapshotPath,
      'clipUrl': clipUrl,
      'clipPath': clipPath,
      'clipDurationMillis': clipDurationMillis,
      'clipPrebufferMillis': clipPrebufferMillis,
      'incidentId': incidentId,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  factory CameraEvent.fromMap({
    required String id,
    required Map<String, dynamic> map,
  }) {
    final occurredAt = _readDateTime(map['occurredAt']) ?? DateTime.now();

    return CameraEvent(
      id: id,
      cameraId: map['cameraId'] as String? ?? '',
      ownerId: map['ownerId'] as String? ?? '',
      type: _typeFromString(map['type'] as String?),
      status: _statusFromString(map['status'] as String?),
      occurredAt: occurredAt,
      lastOccurredAt: _readDateTime(map['lastOccurredAt']) ?? occurredAt,
      occurrenceCount: (map['occurrenceCount'] as num?)?.toInt() ?? 1,
      source: map['source'] as String? ?? 'unknown',
      confidence: (map['confidence'] as num?)?.toDouble(),
      snapshotUrl: map['snapshotUrl'] as String?,
      snapshotPath: map['snapshotPath'] as String?,
      clipUrl: map['clipUrl'] as String?,
      clipPath: map['clipPath'] as String?,
      clipDurationMillis: (map['clipDurationMillis'] as num?)?.toInt(),
      clipPrebufferMillis: (map['clipPrebufferMillis'] as num?)?.toInt(),
      incidentId: map['incidentId'] as String?,
      createdAt: _readDateTime(map['createdAt']) ?? occurredAt,
      updatedAt: _readDateTime(map['updatedAt']) ?? occurredAt,
    );
  }

  CameraEvent copyWith({
    String? id,
    String? cameraId,
    String? ownerId,
    CameraEventType? type,
    CameraEventStatus? status,
    DateTime? occurredAt,
    DateTime? lastOccurredAt,
    int? occurrenceCount,
    String? source,
    double? confidence,
    String? snapshotUrl,
    String? snapshotPath,
    String? clipUrl,
    String? clipPath,
    int? clipDurationMillis,
    int? clipPrebufferMillis,
    String? incidentId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CameraEvent(
      id: id ?? this.id,
      cameraId: cameraId ?? this.cameraId,
      ownerId: ownerId ?? this.ownerId,
      type: type ?? this.type,
      status: status ?? this.status,
      occurredAt: occurredAt ?? this.occurredAt,
      lastOccurredAt: lastOccurredAt ?? this.lastOccurredAt,
      occurrenceCount: occurrenceCount ?? this.occurrenceCount,
      source: source ?? this.source,
      confidence: confidence ?? this.confidence,
      snapshotUrl: snapshotUrl ?? this.snapshotUrl,
      snapshotPath: snapshotPath ?? this.snapshotPath,
      clipUrl: clipUrl ?? this.clipUrl,
      clipPath: clipPath ?? this.clipPath,
      clipDurationMillis: clipDurationMillis ?? this.clipDurationMillis,
      clipPrebufferMillis: clipPrebufferMillis ?? this.clipPrebufferMillis,
      incidentId: incidentId ?? this.incidentId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

String _typeToString(CameraEventType type) {
  switch (type) {
    case CameraEventType.motion:
      return 'motion';

    case CameraEventType.person:
      return 'person';

    case CameraEventType.vehicle:
      return 'vehicle';

    case CameraEventType.sound:
      return 'sound';

    case CameraEventType.tamper:
      return 'tamper';

    case CameraEventType.cameraOffline:
      return 'camera_offline';

    case CameraEventType.cameraOnline:
      return 'camera_online';

    case CameraEventType.unknown:
      return 'unknown';
  }
}

CameraEventType _typeFromString(String? value) {
  switch (value) {
    case 'motion':
      return CameraEventType.motion;

    case 'person':
      return CameraEventType.person;

    case 'vehicle':
      return CameraEventType.vehicle;

    case 'sound':
      return CameraEventType.sound;

    case 'tamper':
      return CameraEventType.tamper;

    case 'camera_offline':
      return CameraEventType.cameraOffline;

    case 'camera_online':
      return CameraEventType.cameraOnline;

    default:
      return CameraEventType.unknown;
  }
}

String _statusToString(CameraEventStatus status) {
  switch (status) {
    case CameraEventStatus.newEvent:
      return 'new';

    case CameraEventStatus.viewed:
      return 'viewed';

    case CameraEventStatus.dismissed:
      return 'dismissed';

    case CameraEventStatus.escalated:
      return 'escalated';
  }
}

CameraEventStatus _statusFromString(String? value) {
  switch (value) {
    case 'viewed':
      return CameraEventStatus.viewed;

    case 'dismissed':
      return CameraEventStatus.dismissed;

    case 'escalated':
      return CameraEventStatus.escalated;

    case 'new':
    default:
      return CameraEventStatus.newEvent;
  }
}

DateTime? _readDateTime(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  if (value is String) {
    return DateTime.tryParse(value);
  }

  return null;
}
