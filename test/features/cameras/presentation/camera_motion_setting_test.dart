import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/domain/camera_motion_preference.dart';
import 'package:safehood/features/cameras/presentation/widgets/camera_motion_setting.dart';

void main() {
  testWidgets('the motion control can reapply a saved choice or change it', (
    tester,
  ) async {
    final changes = <CameraMotionPreference>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraMotionSetting(
            preference: CameraMotionPreference.historyAndAlert,
            onChanged: changes.add,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Wykrywanie ruchu'));
    await tester.pumpAndSettle();
    expect(find.text('Wyłączone'), findsOneWidget);
    expect(find.text('Tylko historia'), findsOneWidget);

    // Reapplying the selected choice also supports old Bridge-only settings.
    await tester.tap(
      find.widgetWithText(SimpleDialogOption, 'Historia i alert'),
    );
    await tester.pumpAndSettle();
    expect(changes, [CameraMotionPreference.historyAndAlert]);

    await tester.tap(find.text('Wykrywanie ruchu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tylko historia'));
    await tester.pumpAndSettle();
    expect(changes, [
      CameraMotionPreference.historyAndAlert,
      CameraMotionPreference.history,
    ]);
  });
}
