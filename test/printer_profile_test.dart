import 'package:boomprint/printer_profile.dart';
import 'package:boomprint/printer_url_formats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local profile exposes control and built-in camera urls', () {
    final profile = PrinterProfile.fromLocalPrinterFields(
      id: 'active',
      displayName: 'Active printer',
      printerType: PrinterUrlType.bambuX2D,
      printerIp: '192.168.1.50',
      serialNumber: '00M000000000000',
      accessCode: '12345678',
      cameraStreamCount: 2,
    );

    expect(profile.urls, hasLength(3));
    expect(profile.builtInUrls, hasLength(3));
    expect(profile.cameraUrls, hasLength(2));
    expect(profile.selectedUrl?.id, 'control');
    expect(profile.cameraUrls.first.url, contains('/streaming/live/1'));
    expect(profile.cameraUrls.last.url, contains('/streaming/live/2'));
  });

  test('custom control url is preserved as a custom record', () {
    final profile = PrinterProfile.fromLocalPrinterFields(
      id: 'active',
      displayName: 'Active printer',
      printerType: PrinterUrlType.custom,
      printerIp: '192.168.1.50',
      serialNumber: '00M000000000000',
      accessCode: '12345678',
      customUrl: 'rtsp://example.local/live',
    );

    expect(profile.urls, hasLength(2));
    expect(profile.customUrls, hasLength(1));
    expect(profile.customUrls.single.url, 'rtsp://example.local/live');
  });
}
