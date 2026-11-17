import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/auth/presentation/auth_gate.dart';

void main() {
  testWidgets('allows relogin while the first profile response is pending', (
    tester,
  ) async {
    final signingOut = Completer<void>();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileConnectionScreen(
          onSignOut: () {
            attempts++;
            return signingOut.future;
          },
        ),
      ),
    );
    expect(find.text('Łączenie z profilem...'), findsOneWidget);
    await tester.tap(find.text('Zaloguj się ponownie'));
    await tester.pump();
    final action = find.widgetWithText(TextButton, 'Wylogowuję…');
    expect(tester.widget<TextButton>(action).onPressed, isNull);
    expect(attempts, 1);
    signingOut.complete();
    await tester.pump();
    expect(find.text('Zaloguj się ponownie'), findsOneWidget);
  });

  testWidgets('reports a signout failure and offers a retry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileConnectionScreen(
          loadFailed: true,
          onSignOut: () async => throw StateError('Signout failed'),
        ),
      ),
    );
    await tester.tap(find.text('Zaloguj się ponownie'));
    await tester.pumpAndSettle();
    expect(
      find.text('Nie udało się wylogować. Spróbuj ponownie.'),
      findsOneWidget,
    );
    expect(find.text('Zaloguj się ponownie'), findsOneWidget);
  });
}
