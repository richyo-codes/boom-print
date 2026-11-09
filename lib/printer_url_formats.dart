enum PrinterUrlType {
  bambuX1C,
  bambuP1S,
  bambuX2D,
  bambuH2C,
  bambuH2D,
  bambuH2S,
  genericRtsp,
  custom,
}

extension PrinterUrlTypeX on PrinterUrlType {
  String get displayName => switch (this) {
    PrinterUrlType.bambuX1C => 'Bambu X1C',
    PrinterUrlType.bambuP1S => 'Bambu P1S',
    PrinterUrlType.bambuX2D => 'Bambu X2D',
    PrinterUrlType.bambuH2C => 'Bambu H2C',
    PrinterUrlType.bambuH2D => 'Bambu H2D',
    PrinterUrlType.bambuH2S => 'Bambu H2S',
    PrinterUrlType.genericRtsp => 'Generic RTSP',
    PrinterUrlType.custom => 'Custom',
  };

  // Stable key used for persistence
  String get storageKey => switch (this) {
    PrinterUrlType.bambuX1C => 'bambu_x1c',
    PrinterUrlType.bambuP1S => 'bambu_p1s',
    PrinterUrlType.bambuX2D => 'bambu_x2d',
    PrinterUrlType.bambuH2C => 'bambu_h2c',
    PrinterUrlType.bambuH2D => 'bambu_h2d',
    PrinterUrlType.bambuH2S => 'bambu_h2s',
    PrinterUrlType.genericRtsp => 'generic_rtsp',
    PrinterUrlType.custom => 'custom',
  };

  String get template => switch (this) {
    PrinterUrlType.bambuX1C =>
      'rtsps://bblp:\${specialcode}@\${printerip}:322/streaming/live/1',
    PrinterUrlType.bambuP1S =>
      'rtsps://bblp:\${specialcode}@\${printerip}:322/streaming/live/1',
    PrinterUrlType.bambuX2D =>
      'rtsps://bblp:\${specialcode}@\${printerip}:322/streaming/live/1',
    PrinterUrlType.bambuH2C =>
      'rtsps://bblp:\${specialcode}@\${printerip}:322/streaming/live/1',
    PrinterUrlType.bambuH2D =>
      'rtsps://bblp:\${specialcode}@\${printerip}:322/streaming/live/1',
    PrinterUrlType.bambuH2S =>
      'rtsps://bblp:\${specialcode}@\${printerip}:322/streaming/live/1',
    PrinterUrlType.genericRtsp => 'rtsp://\${printerip}:554/stream',
    PrinterUrlType.custom => '',
  };

  bool get isBambuFamily => switch (this) {
    PrinterUrlType.bambuX1C ||
    PrinterUrlType.bambuP1S ||
    PrinterUrlType.bambuX2D ||
    PrinterUrlType.bambuH2C ||
    PrinterUrlType.bambuH2D ||
    PrinterUrlType.bambuH2S => true,
    PrinterUrlType.genericRtsp || PrinterUrlType.custom => false,
  };

  bool get isIndexedDualCameraBambu => switch (this) {
    PrinterUrlType.bambuH2C ||
    PrinterUrlType.bambuH2D ||
    PrinterUrlType.bambuH2S => true,
    PrinterUrlType.bambuX1C ||
    PrinterUrlType.bambuP1S ||
    PrinterUrlType.bambuX2D ||
    PrinterUrlType.genericRtsp ||
    PrinterUrlType.custom => false,
  };

  int get defaultCameraCount => switch (this) {
    PrinterUrlType.bambuH2C ||
    PrinterUrlType.bambuH2D ||
    PrinterUrlType.bambuH2S => 2,
    PrinterUrlType.bambuX1C ||
    PrinterUrlType.bambuP1S ||
    // The X2D exposes one LAN RTSP stream. Do not generate a second
    // /streaming/live/<n> URL merely because the machine has multiple views.
    PrinterUrlType.bambuX2D ||
    PrinterUrlType.genericRtsp ||
    PrinterUrlType.custom => 1,
  };

  int get maxCameraCount => isIndexedDualCameraBambu ? 2 : 1;

  static PrinterUrlType parse(String? value) {
    switch ((value ?? '').trim().toLowerCase()) {
      case 'bambu x1c':
      case 'bambu_x1c':
        return PrinterUrlType.bambuX1C;
      case 'bambu p1s':
      case 'bambu_p1s':
        return PrinterUrlType.bambuP1S;
      case 'bambu x2d':
      case 'bambu_x2d':
      case 'bambu x2c':
      case 'bambu_x2c':
        return PrinterUrlType.bambuX2D;
      case 'bambu h2c':
      case 'bambu_h2c':
        return PrinterUrlType.bambuH2C;
      case 'bambu h2d':
      case 'bambu_h2d':
        return PrinterUrlType.bambuH2D;
      case 'bambu h2s':
      case 'bambu_h2s':
        return PrinterUrlType.bambuH2S;
      case 'generic rtsp':
      case 'generic_rtsp':
        return PrinterUrlType.genericRtsp;
      case 'custom':
      default:
        return PrinterUrlType.custom;
    }
  }
}
