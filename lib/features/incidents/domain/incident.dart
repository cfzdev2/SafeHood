import 'package:cloud_firestore/cloud_firestore.dart';

enum IncidentStatus {
  active,
  resolved,
}

enum IncidentResponseStatus {
  watching,
  going,
  onSite,
}

class Incident {
  final String id;

  final String reporterId;
  final String reporterName;

  final String cameraId;
  final String cameraName;

  final String title;
  final String? description;

  final DateTime createdAt;
  final DateTime? expiresAt;

  final IncidentStatus status;

  final bool hasRecording;
  final int? recordingDurationSeconds;

  final List<String> participantIds;

  const Incident({
    required this.id,
    required this.reporterId,
    required this.reporterName,
    required this.cameraId,
    required this.cameraName,
    required this.title,
    this.description,
    required this.createdAt,
    this.expiresAt,
    required this.status,
    required this.hasRecording,
    this.recordingDurationSeconds,
    this.participantIds = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'reporterId': reporterId,
      'reporterName': reporterName,
      'cameraId': cameraId,
      'cameraName': cameraName,
      'title': title,
      'description': description,
      'createdAt': createdAt,
      'expiresAt': expiresAt,
      'status': status.name,
      'hasRecording': hasRecording,
      'recordingDurationSeconds':
          recordingDurationSeconds,
      'participantIds': participantIds,
    };
  }

  factory Incident.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    final rawParticipantIds =
        map['participantIds'];

    final participantIds =
        rawParticipantIds is List
            ? rawParticipantIds
                .whereType<String>()
                .toList()
            : <String>[];

    return Incident(
      id: id,
      reporterId:
          map['reporterId'] as String? ?? '',
      reporterName:
          map['reporterName'] as String? ?? '',
      cameraId:
          map['cameraId'] as String? ?? '',
      cameraName:
          map['cameraName'] as String? ?? '',
      title:
          map['title'] as String? ?? '',
      description:
          map['description'] as String?,
      createdAt: _dateFromValue(
        map['createdAt'],
      ),
      expiresAt: map['expiresAt'] == null
          ? null
          : _dateFromValue(
              map['expiresAt'],
            ),
      status: _statusFromString(
        map['status'] as String?,
      ),
      hasRecording:
          map['hasRecording'] as bool? ?? false,
      recordingDurationSeconds:
          (map['recordingDurationSeconds']
                  as num?)
              ?.toInt(),
      participantIds: participantIds,
    );
  }

  static IncidentStatus _statusFromString(
    String? value,
  ) {
    if (value == 'resolved') {
      return IncidentStatus.resolved;
    }

    return IncidentStatus.active;
  }

  static DateTime _dateFromValue(
    dynamic value,
  ) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    return DateTime.now();
  }
}

class IncidentResponse {
  final String userId;
  final String firstName;
  final IncidentResponseStatus status;
  final DateTime updatedAt;

  const IncidentResponse({
    required this.userId,
    required this.firstName,
    required this.status,
    required this.updatedAt,
  });

  factory IncidentResponse.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return IncidentResponse(
      userId:
          map['userId'] as String? ?? id,
      firstName:
          map['firstName'] as String? ??
              'Użytkownik',
      status: _responseStatusFromString(
        map['status'] as String?,
      ),
      updatedAt: Incident._dateFromValue(
        map['updatedAt'],
      ),
    );
  }

  static IncidentResponseStatus
      _responseStatusFromString(
    String? value,
  ) {
    switch (value) {
      case 'going':
        return IncidentResponseStatus.going;

      case 'onSite':
        return IncidentResponseStatus.onSite;

      case 'watching':
      default:
        return IncidentResponseStatus.watching;
    }
  }
}

class IncidentContact {
  final String reporterName;
  final String phoneNumber;

  const IncidentContact({
    required this.reporterName,
    required this.phoneNumber,
  });
}