import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/camera_events/domain/camera_event_ai_metadata.dart';
import 'package:safehood/features/camera_events/presentation/widgets/camera_event_ai_summary.dart';

void main() {
  testWidgets('pokazuje klasy, pewność, czas i liczbę klatek', (tester) async {
    final firstSeenAt = DateTime.utc(2026, 10, 9, 12);
    final metadata = CameraEventAiMetadata(
      schemaVersion: 1,
      totalObjects: 2,
      personCount: 1,
      vehicleCount: 1,
      classCounts: const {'person': 1, 'bus': 1},
      maximumConfidence: 0.94,
      firstSeenAt: firstSeenAt,
      lastSeenAt: firstSeenAt.add(const Duration(milliseconds: 1500)),
      detectionFrameCount: 7,
      modelIds: const ['yolox-nano-coco-c789161e'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CameraEventAiSummary(metadata: metadata),
          ),
        ),
      ),
    );

    expect(find.text('Analiza AI'), findsOneWidget);
    expect(find.text('Osoby: 1'), findsOneWidget);
    expect(find.text('Autobusy: 1'), findsOneWidget);
    expect(find.text('94%'), findsOneWidget);
    expect(find.text('1,5 s'), findsOneWidget);
    expect(find.text('Potwierdzone na 7 klatkach'), findsOneWidget);
  });
}
