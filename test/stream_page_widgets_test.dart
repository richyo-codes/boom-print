import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/bambu_mqtt.dart';
import 'package:boomprint/stream_page_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fullCard = BambuHmsEvent(code: 0x00030004, attr: 0x05000100);
  const heaterFault = BambuHmsEvent(code: 0x00010003, attr: 0x03000100);

  Future<void> showStatus(WidgetTester tester, BambuPrintStatus status) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PrinterFaultBanner(status: status)),
      ),
    );
  }

  testWidgets('shows a dismissible MicroSD maintenance notice', (tester) async {
    const status = BambuPrintStatus(
      gcodeState: 'PAUSE',
      hms: [BambuHmsEvent(code: 0x00030004, attr: 0x05000100)],
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PrinterFaultBanner(status: status)),
      ),
    );

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.textContaining('MicroSD card is full'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.textContaining('MicroSD card is full'), findsNothing);
  });

  testWidgets('MQTT full-card reports stay dismissed until cleared', (
    tester,
  ) async {
    final mqtt = BambuMqtt(
      const BambuLanConfig(
        printerIp: '192.0.2.1',
        accessCode: 'test',
        serial: 'test',
      ),
    );
    BambuPrintStatus report(int percent) => mqtt.parsePrintStatus({
      'print': {
        'gcode_state': 'RUNNING',
        'mc_percent': percent,
        'hms': [
          {'attr': 0x05000100, 'code': 0x00030004},
        ],
      },
    })!;

    await showStatus(tester, report(5));
    expect(find.text('HMS 0500-0100-0003-0004'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await showStatus(tester, report(6));
    expect(find.textContaining('MicroSD card is full'), findsNothing);

    await showStatus(tester, const BambuPrintStatus(gcodeState: 'RUNNING'));
    await showStatus(tester, report(7));
    expect(find.textContaining('MicroSD card is full'), findsOneWidget);
  });

  testWidgets(
    'dismisses each condition independently across reordered reports',
    (tester) async {
      await showStatus(
        tester,
        const BambuPrintStatus(
          gcodeState: 'PAUSE',
          hms: [fullCard, heaterFault],
        ),
      );
      expect(find.textContaining('over temperature'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss').first);
      await showStatus(
        tester,
        const BambuPrintStatus(
          gcodeState: 'PAUSE',
          hms: [heaterFault, fullCard],
        ),
      );
      expect(find.textContaining('MicroSD card is full'), findsNothing);
      expect(find.textContaining('over temperature'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.byTooltip('Dismiss'), findsNothing);
    },
  );

  testWidgets('full-card notice does not mask a print error', (tester) async {
    await showStatus(
      tester,
      const BambuPrintStatus(
        gcodeState: 'PAUSE',
        hms: [fullCard],
        printError: 12,
        printerMessage: 'Filament ran out',
      ),
    );
    expect(find.textContaining('MicroSD card is full'), findsOneWidget);
    expect(find.text('Filament ran out'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss').last);
    await tester.pump();
    expect(find.text('Filament ran out'), findsNothing);
    expect(find.textContaining('MicroSD card is full'), findsOneWidget);
  });

  testWidgets('copies description and HMS code', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await showStatus(
      tester,
      const BambuPrintStatus(gcodeState: 'RUNNING', hms: [fullCard]),
    );
    await tester.tap(find.byTooltip('Copy printer message'));
    await tester.pump();
    expect(copied, contains('MicroSD card is full'));
    expect(copied, contains('0500-0100-0003-0004'));
  });

  testWidgets('unknown warnings remain readable and fit a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await showStatus(
      tester,
      const BambuPrintStatus(
        gcodeState: 'RUNNING',
        hms: [BambuHmsEvent(code: 0x000300ff, attr: 0xffffffff)],
      ),
    );
    expect(find.textContaining('no available description'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.byTooltip('Dismiss'), findsNothing);
  });
}
