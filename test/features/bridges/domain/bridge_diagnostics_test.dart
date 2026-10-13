import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/bridges/domain/bridge_diagnostics.dart';

Map<String, dynamic> diagnosticsMap({
  String health = 'healthy',
  DateTime? updatedAt,
  int framesReceived = 30,
  int framesAnalyzed = 28,
  int framesDropped = 1,
  int inferenceErrors = 1,
}) {
  return {
    'schemaVersion': 1,
    'health': health,
    'updatedAt': Timestamp.fromDate(
      updatedAt ?? DateTime.utc(2026, 10, 12, 17),
    ),
    'uptimeSeconds': 120,
    'rssBytes': 200 * 1024 * 1024,
    'heapUsedBytes': 75 * 1024 * 1024,
    'aiExpectedSessions': 2,
    'aiActiveSessions': 2,
    'aiRunningSessions': 2,
    'aiStalledSessions': 0,
    'framesReceived': framesReceived,
    'framesAnalyzed': framesAnalyzed,
    'framesDropped': framesDropped,
    'inferenceErrors': inferenceErrors,
    'eventErrors': 0,
    'oldestSessionAgeSeconds': 99,
    'lastFrameAgeSeconds': 5,
    'schedulerBusy': true,
    'pendingInference': 1,
    'pendingEvents': 2,
    'pendingSnapshots': 1,
    'pendingClips': 1,
    'recordingBuffers': 2,
    'activeRecordings': 1,
  };
}

void main() {
  test('odczytuje poprawną diagnostykę Bridge', () {
    final diagnostics = BridgeDiagnostics.tryParse(diagnosticsMap());

    expect(diagnostics, isNotNull);
    expect(diagnostics!.health, BridgeDiagnosticHealth.healthy);
    expect(diagnostics.aiExpectedSessions, 2);
    expect(diagnostics.aiActiveSessions, 2);
    expect(diagnostics.framesAnalyzed, 28);
    expect(diagnostics.pendingUploads, 4);
    expect(diagnostics.droppedFramePercent, 3);
    expect(diagnostics.rssMebibytes, 200);
  });

  test('stary raport jest oznaczany jako nieznany', () {
    final diagnostics = BridgeDiagnostics.tryParse(
      diagnosticsMap(updatedAt: DateTime.utc(2026, 10, 12, 16)),
    );

    expect(
      diagnostics!.healthAt(DateTime.utc(2026, 10, 12, 17)),
      BridgeDiagnosticHealth.unknown,
    );
  });

  test('rozpoznaje aktualny raport', () {
    final now = DateTime.utc(2026, 10, 12, 17);
    final diagnostics = BridgeDiagnostics.tryParse(
      diagnosticsMap(updatedAt: now.subtract(const Duration(seconds: 60))),
    );

    expect(diagnostics!.isFreshAt(now), isTrue);
    expect(diagnostics.healthAt(now), BridgeDiagnosticHealth.healthy);
    expect(diagnostics.lastFrameAgeAt(now), 65);
  });

  test('odrzuca nieznany schemat i niespójne liczniki', () {
    expect(
      BridgeDiagnostics.tryParse({...diagnosticsMap(), 'schemaVersion': 2}),
      isNull,
    );

    expect(
      BridgeDiagnostics.tryParse(
        diagnosticsMap(framesAnalyzed: 30, framesDropped: 1),
      ),
      isNull,
    );
  });

  test('odrzuca nieprawidłowy wiek ostatniej klatki', () {
    expect(
      BridgeDiagnostics.tryParse({
        ...diagnosticsMap(),
        'lastFrameAgeSeconds': '5',
      }),
      isNull,
    );
  });
}
