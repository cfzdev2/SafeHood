import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:safehood/features/cameras/presentation/widgets/camera_availability_builder.dart';
import 'package:safehood/features/cameras/presentation/widgets/camera_card.dart';

void main() {
  testWidgets('a saved camera goes offline and comes back on the list', (
    tester,
  ) async {
    const camera = Camera(
      id: 'saved-camera',
      name: 'Kamera',
      locationName: 'Dom',
      brand: 'Test',
      model: 'Test',
      isOnline: true,
      motionDetectionEnabled: false,
      hasSdCard: false,
      connectionType: CameraConnectionType.onvif,
    );
    final checks = <Completer<CameraAvailability>>[];
    Widget screen({required bool enabled}) => MaterialApp(
      home: Scaffold(
        body: CameraAvailabilityBuilder(
          camera: camera,
          enabled: enabled,
          check: (_) {
            final check = Completer<CameraAvailability>();
            checks.add(check);
            return check.future;
          },
          builder: (_, availability) =>
              CameraCard(camera: camera, availability: availability),
        ),
      ),
    );

    await tester.pumpWidget(screen(enabled: true));
    expect(find.text('Sprawdzanie kamery…'), findsOneWidget);
    expect(find.text('Kamera online'), findsNothing);

    checks.single.complete(CameraAvailability.online);
    await tester.pumpAndSettle();
    expect(find.text('Kamera online'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    checks[1].complete(CameraAvailability.offline);
    await tester.pumpAndSettle();
    expect(find.text('Kamera offline'), findsOneWidget);
    expect(find.text('Kamera online'), findsNothing);

    await tester.pump(const Duration(seconds: 10));
    checks[2].complete(CameraAvailability.online);
    await tester.pumpAndSettle();
    expect(find.text('Kamera online'), findsOneWidget);

    await tester.pumpWidget(screen(enabled: false));
    await tester.pump(const Duration(minutes: 1));
    expect(checks, hasLength(3));
    expect(find.text('Kamera online'), findsNothing);

    await tester.pumpWidget(screen(enabled: true));
    expect(checks, hasLength(4));
    expect(find.text('Sprawdzanie kamery…'), findsOneWidget);
    checks[3].complete(CameraAvailability.offline);
    await tester.pumpAndSettle();
    expect(find.text('Kamera offline'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
