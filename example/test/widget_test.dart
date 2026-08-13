import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util_example/main.dart';

void main() {
  testWidgets('keeps every NFC action disabled until NFC is known to be reachable', (tester) async {
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

    for (final label in ['Read', 'Write text', 'Write poster', 'Inspect tag', 'Scan many']) {
      expect(buttonLabelled(label).onPressed, isNull, reason: '"$label" must be disabled');
    }

    // Stopping is offered only while something is running -- it lives in the busy strip,
    // which is not built at all when idle. Offering it on an idle app said nothing, and it
    // was the only live control on a device with no NFC.
    expect(find.text('Stop session'), findsNothing);

    // The NDEF codec is pure Dart: no tag, no session, no radio. It has to stay reachable
    // precisely where everything else is not, which is also the only part of this app a
    // widget test can drive end to end.
    expect(buttonLabelled('Build & decode NDEF').onPressed, isNotNull);
  });

  testWidgets('builds and decodes an NDEF message with no platform behind it', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Build & decode NDEF'));
    await tester.pump();

    // The round trip is the assertion the action itself makes; this checks it reported a
    // pass rather than that it merely ran.
    expect(find.textContaining('fromBytes(bytes) == message -> true'), findsOneWidget);
    expect(find.textContaining('uri: https://pub.dev/packages/nfc_util'), findsOneWidget);
    expect(find.textContaining('text[tr]: merhaba dünya'), findsOneWidget);
  });
}
