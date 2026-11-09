import 'package:boomprint/connection_preflight.dart';
import 'package:boomprint/printer_camera_streams.dart';
import 'package:boomprint/printer_url_formats.dart';
import 'package:boomprint/settings_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrates the mistaken X2C settings key to X2D', () {
    expect(PrinterUrlTypeX.parse('bambu_x2c'), PrinterUrlType.bambuX2D);
    expect(PrinterUrlType.bambuX2D.storageKey, 'bambu_x2d');
  });

  test('builds one API-exposed built-in camera stream for X2D', () {
    final settings = AppSettings(
      specialCode: '12345678',
      printerIp: '192.168.1.50',
      serialNumber: '00M000000000000',
      selectedFormat: PrinterUrlType.bambuX2D,
      customUrl: '',
    );

    final streams = buildPrinterCameraStreams(settings);

    expect(streams, hasLength(1));
    expect(streams[0].label, 'Camera');
    expect(
      streams[0].url,
      'rtsps://bblp:12345678@192.168.1.50:322/streaming/live/1',
    );
  });
}
