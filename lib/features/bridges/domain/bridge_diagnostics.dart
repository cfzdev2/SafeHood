import 'package:cloud_firestore/cloud_firestore.dart';

enum BridgeDiagnosticHealth { healthy, degraded, problem, idle, unknown }

class BridgeDiagnostics {
  final int schemaVersion;
  final BridgeDiagnosticHealth health;
  final DateTime updatedAt;
  final int uptimeSeconds;
  final int rssBytes;
  final int heapUsedBytes;
  final int aiExpectedSessions;
  final int aiActiveSessions;
  final int aiRunningSessions;
  final int aiStalledSessions;
  final int framesReceived;
  final int framesAnalyzed;
  final int framesDropped;
  final int inferenceErrors;
  final int eventErrors;
  final int? oldestSessionAgeSeconds;
  final int? lastFrameAgeSeconds;
  final bool schedulerBusy;
  final int pendingInference;
  final int pendingEvents;
  final int pendingSnapshots;
  final int pendingClips;
  final int recordingBuffers;
  final int activeRecordings;

  const BridgeDiagnostics({
    required this.schemaVersion,
    required this.health,
    required this.updatedAt,
    required this.uptimeSeconds,
    required this.rssBytes,
    required this.heapUsedBytes,
    required this.aiExpectedSessions,
    required this.aiActiveSessions,
    required this.aiRunningSessions,
    required this.aiStalledSessions,
    required this.framesReceived,
    required this.framesAnalyzed,
    required this.framesDropped,
    required this.inferenceErrors,
    required this.eventErrors,
    required this.oldestSessionAgeSeconds,
    required this.lastFrameAgeSeconds,
    required this.schedulerBusy,
    required this.pendingInference,
    required this.pendingEvents,
    required this.pendingSnapshots,
    required this.pendingClips,
    required this.recordingBuffers,
    required this.activeRecordings,
  });

  int get pendingUploads => pendingEvents + pendingSnapshots + pendingClips;

  int get droppedFramePercent {
    if (framesReceived == 0) {
      return 0;
    }

    return ((framesDropped * 100) / framesReceived)
        .round()
        .clamp(0, 100)
        .toInt();
  }

  double get rssMebibytes => rssBytes / (1024 * 1024);

  bool isFreshAt(DateTime now) {
    final age = now.difference(updatedAt);

    return age >= const Duration(seconds: -30) &&
        age <= const Duration(seconds: 90);
  }

  BridgeDiagnosticHealth healthAt(DateTime now) {
    return isFreshAt(now) ? health : BridgeDiagnosticHealth.unknown;
  }

  int? lastFrameAgeAt(DateTime now) {
    final reportedAge = lastFrameAgeSeconds;

    if (reportedAge == null) {
      return null;
    }

    final reportAge = now.difference(updatedAt).inSeconds.clamp(0, 90).toInt();

    return reportedAge + reportAge;
  }

  static BridgeDiagnostics? tryParse(dynamic value) {
    if (value is! Map) {
      return null;
    }

    final schemaVersion = _readInteger(value['schemaVersion']);
    final updatedAt = _readDateTime(value['updatedAt']);
    final uptimeSeconds = _readNonNegativeInteger(value['uptimeSeconds']);
    final rssBytes = _readNonNegativeInteger(value['rssBytes']);
    final heapUsedBytes = _readNonNegativeInteger(value['heapUsedBytes']);
    final aiActiveSessions = _readNonNegativeInteger(value['aiActiveSessions']);
    final aiExpectedSessions = _readNonNegativeInteger(
      value['aiExpectedSessions'],
    );
    final aiRunningSessions = _readNonNegativeInteger(
      value['aiRunningSessions'],
    );
    final aiStalledSessions = _readNonNegativeInteger(
      value['aiStalledSessions'],
    );
    final framesReceived = _readNonNegativeInteger(value['framesReceived']);
    final framesAnalyzed = _readNonNegativeInteger(value['framesAnalyzed']);
    final framesDropped = _readNonNegativeInteger(value['framesDropped']);
    final inferenceErrors = _readNonNegativeInteger(value['inferenceErrors']);
    final eventErrors = _readNonNegativeInteger(value['eventErrors']);
    final oldestSessionAgeSeconds = _readOptionalNonNegativeInteger(
      value['oldestSessionAgeSeconds'],
    );
    final lastFrameAgeSeconds = _readOptionalNonNegativeInteger(
      value['lastFrameAgeSeconds'],
    );
    final pendingInference = _readNonNegativeInteger(value['pendingInference']);
    final pendingEvents = _readNonNegativeInteger(value['pendingEvents']);
    final pendingSnapshots = _readNonNegativeInteger(value['pendingSnapshots']);
    final pendingClips = _readNonNegativeInteger(value['pendingClips']);
    final recordingBuffers = _readNonNegativeInteger(value['recordingBuffers']);
    final activeRecordings = _readNonNegativeInteger(value['activeRecordings']);
    final health = _readHealth(value['health']);
    final schedulerBusy = value['schedulerBusy'];

    if (schemaVersion != 1 ||
        updatedAt == null ||
        uptimeSeconds == null ||
        rssBytes == null ||
        heapUsedBytes == null ||
        heapUsedBytes > rssBytes ||
        aiExpectedSessions == null ||
        aiActiveSessions == null ||
        aiRunningSessions == null ||
        aiRunningSessions > aiActiveSessions ||
        aiStalledSessions == null ||
        aiStalledSessions > aiActiveSessions ||
        framesReceived == null ||
        framesAnalyzed == null ||
        framesDropped == null ||
        inferenceErrors == null ||
        framesAnalyzed + framesDropped + inferenceErrors > framesReceived ||
        eventErrors == null ||
        oldestSessionAgeSeconds == _invalidOptionalInteger ||
        lastFrameAgeSeconds == _invalidOptionalInteger ||
        schedulerBusy is! bool ||
        pendingInference == null ||
        pendingEvents == null ||
        pendingSnapshots == null ||
        pendingClips == null ||
        recordingBuffers == null ||
        activeRecordings == null ||
        health == BridgeDiagnosticHealth.unknown) {
      return null;
    }

    return BridgeDiagnostics(
      schemaVersion: 1,
      health: health,
      updatedAt: updatedAt,
      uptimeSeconds: uptimeSeconds,
      rssBytes: rssBytes,
      heapUsedBytes: heapUsedBytes,
      aiExpectedSessions: aiExpectedSessions,
      aiActiveSessions: aiActiveSessions,
      aiRunningSessions: aiRunningSessions,
      aiStalledSessions: aiStalledSessions,
      framesReceived: framesReceived,
      framesAnalyzed: framesAnalyzed,
      framesDropped: framesDropped,
      inferenceErrors: inferenceErrors,
      eventErrors: eventErrors,
      oldestSessionAgeSeconds: oldestSessionAgeSeconds,
      lastFrameAgeSeconds: lastFrameAgeSeconds,
      schedulerBusy: schedulerBusy,
      pendingInference: pendingInference,
      pendingEvents: pendingEvents,
      pendingSnapshots: pendingSnapshots,
      pendingClips: pendingClips,
      recordingBuffers: recordingBuffers,
      activeRecordings: activeRecordings,
    );
  }

  static const int _invalidOptionalInteger = -1;

  static int? _readInteger(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }

    return null;
  }

  static int? _readNonNegativeInteger(dynamic value) {
    final parsed = _readInteger(value);

    return parsed != null && parsed >= 0 ? parsed : null;
  }

  static int? _readOptionalNonNegativeInteger(dynamic value) {
    if (value == null) {
      return null;
    }

    return _readNonNegativeInteger(value) ?? _invalidOptionalInteger;
  }

  static DateTime? _readDateTime(dynamic value) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    return null;
  }

  static BridgeDiagnosticHealth _readHealth(dynamic value) {
    switch (value) {
      case 'healthy':
        return BridgeDiagnosticHealth.healthy;
      case 'degraded':
        return BridgeDiagnosticHealth.degraded;
      case 'problem':
        return BridgeDiagnosticHealth.problem;
      case 'idle':
        return BridgeDiagnosticHealth.idle;
      default:
        return BridgeDiagnosticHealth.unknown;
    }
  }
}
