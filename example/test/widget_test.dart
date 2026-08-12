import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util_example/main.dart';

void main() {
  testWidgets('keeps every action disabled until NFC is known to be reachable', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    // No platform answers in a widget test, so the availability call never resolves and the
    // app stays on its "checking" state. That is the behaviour worth locking in: an app
    // that cannot reach the NFC platform must not offer NFC actions.
    expect(find.text('Checking…'), findsOneWidget);

    // byType matches the exact runtime type, and the buttons are FilledButton /
    // OutlinedButton, so match on the shared supertype instead.
    ButtonStyleButton buttonLabelled(String label) => tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
      ),
    );

    for (final label in ['Read', 'Write text', 'Tag I/O', 'Continuous']) {
      expect(buttonLabelled(label).onPressed, isNull, reason: '"$label" must be disabled');
    }

    // Stopping a session is always safe, so it stays live.
    expect(buttonLabelled('Stop session').onPressed, isNotNull);
  });
}
