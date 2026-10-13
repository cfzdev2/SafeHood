import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/bridges/domain/bridge_diagnostics.dart';
import 'package:safehood/features/bridges/presentation/widgets/bridge_diagnostics_panel.dart';

BridgeDiagnostics diagnostics({
  BridgeDiagnosticHealth health = BridgeDiagnosticHealth.healthy,
  int stalledSessions = 0,
}) {
  return BridgeDiagnostics(
    schemaVersion: 1,
    health: health,
    updatedAt: DateTime.now(),
    uptimeSeconds: 120,
    rssBytes: 200 * 1024 * 1024,
    heapUsedBytes: 75 * 1024 * 1024,
    aiExpectedSessions: 1,
    aiActiveSessions: 1,
    aiRunningSessions: 1,
    aiStalledSessions: stalledSessions,
    framesReceived: 30,
    framesAnalyzed: 29,
    framesDropped: 1,
    inferenceErrors: 0,
    eventErrors: 0,
    oldestSessionAgeSeconds: 99,
    lastFrameAgeSeconds: 5,
    schedulerBusy: false,
    pendingInference: 0,
    pendingEvents: 0,
    pendingSnapshots: 0,
    pendingClips: 0,
    recordingBuffers: 1,
    activeRecordings: 0,
  );
}

Future<void> pumpPanel(
  WidgetTester tester, {
  BridgeDiagnostics? value,
  bool online = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BridgeDiagnosticsPanel(diagnostics: value, bridgeOnline: online),
      ),
    ),
  );
}

void main() {
  testWidgets('pokazuje zdrowy stan i szczegóły po rozwinięciu', (
    tester,
  ) async {
    await pumpPanel(tester, value: diagnostics());

    expect(find.text('AI działa prawidłowo'), findsOneWidget);

    await tester.tap(find.text('AI działa prawidłowo'));
    await tester.pumpAndSettle();

    expect(find.text('29 klatek, 3% pominiętych'), findsOneWidget);
    expect(find.text('200 MiB'), findsOneWidget);
  });

  testWidgets('wyjaśnia brak klatek w zatrzymanej sesji', (tester) async {
    await pumpPanel(
      tester,
      value: diagnostics(
        health: BridgeDiagnosticHealth.problem,
        stalledSessions: 1,
      ),
    );

    expect(find.text('AI wymaga uwagi'), findsOneWidget);
    expect(
      find.text('Co najmniej jedna sesja AI nie otrzymuje klatek.'),
      findsOneWidget,
    );
  });

  testWidgets('starszy Bridge pokazuje brak diagnostyki', (tester) async {
    await pumpPanel(tester);

    expect(find.text('Brak diagnostyki'), findsOneWidget);
    expect(
      find.text('Raport pojawi się po aktualizacji Bridge.'),
      findsOneWidget,
    );
  });
}
