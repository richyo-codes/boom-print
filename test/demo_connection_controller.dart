import 'dart:async';

import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/bambu_mqtt.dart';
import 'package:boomprint/printer_camera_streams.dart';
import 'package:boomprint/printer_firmware.dart';
import 'package:boomprint/connection_controller.dart';
import 'package:boomprint/screenshot_storage.dart';

/// A drop-in replacement for [ConnectionController] that provides realistic
/// mock telemetry for staging marketing screenshots and demo runs.
///
/// When launched with `--demo`, the app uses this controller instead of
/// connecting to a real printer. All UI states (streaming, print status,
/// settings) look identical to a live connection.
///
/// Usage:
///   `flutter run --dart-define=BOOMPRINT_DEMO=true`
///   or
///   `dart tools/seed_demo_screenshots.dart` to seed screenshots first,
///   then run with `--demo`.
class DemoConnectionController extends ConnectionController {
  /// Fake telemetry that cycles through print states for realistic demo.
  late final List<_DemoState> _states;
  int _stateIndex = 0;
  Timer? _stateTimer;
  bool _demoIsStreaming = true;
  String? _demoCurrentStreamUrl = 'rtsp://demo.local/chamber';
  int _demoSelectedCameraIndex = 0;

  /// Override to return true so the UI thinks we're streaming.
  @override
  bool get isStreaming => _demoIsStreaming;

  /// Override to return fake print status.
  @override
  BambuPrintStatus? get lastPrintStatus {
    final state = _states[_stateIndex % _states.length];
    return state.printStatus;
  }

  /// Override to return a fake stream URL (won't actually connect, but UI
  /// will show streaming state with telemetry).
  @override
  String? get currentStreamUrl => _demoCurrentStreamUrl;

  @override
  List<PrinterCameraStream> get cameraStreams => [
    const PrinterCameraStream(
      index: 0,
      label: 'Chamber Camera',
      url: 'rtsp://demo.local/chamber',
    ),
    const PrinterCameraStream(
      index: 1,
      label: 'Object Camera',
      url: 'rtsp://demo.local/object',
    ),
  ];

  @override
  int get selectedCameraIndex => _demoSelectedCameraIndex;

  @override
  String get printerStatus => _states[_stateIndex % _states.length].statusLabel;

  @override
  String? get firmwareVersion => '01.09.01.00 (20250601)';

  @override
  PrinterFirmwareWarning? get firmwareWarning => null;

  @override
  bool? get chamberLightOn => true;

  @override
  bool get mqttConnected => true;

  @override
  String get lightNode => 'work_light';

  DemoConnectionController() : super() {
    _states = _generateDemoStates();
    _startDemoCycle();
  }

  @override
  Future<String?> autoConnectUrl() async => null;

  @override
  Future<void> refreshCameraStreamsFromSettings() async {}

  @override
  Future<void> startStreaming(String url) async {
    _demoCurrentStreamUrl = url;
    _demoIsStreaming = true;
    notifyListeners();
  }

  @override
  Future<void> stopStreaming() async {
    _demoCurrentStreamUrl = null;
    _demoIsStreaming = false;
    notifyListeners();
  }

  @override
  Future<String?> connectMqttFromSavedSettings({
    bool showErrors = false,
  }) async {
    return null;
  }

  @override
  Future<String?> reconnectMqttIfNeeded() async => null;

  List<_DemoState> _generateDemoStates() {
    return [
      _DemoState(
        statusLabel: 'RUNNING 67% • 23m left',
        printStatus: const BambuPrintStatus(
          gcodeState: 'RUNNING',
          percent: 67,
          remainingMinutes: 23,
          gcodeFile: 'Vase_Spiral_1.2mm.gcode',
          layer: 142,
          totalLayers: 210,
          bedTemp: 60.0,
          bedTarget: 60.0,
          nozzleTemp: 240.5,
          nozzleTarget: 240.0,
          chamberTemp: 35.2,
          speedLevel: 2,
          speedMag: 100,
          subtaskName: 'Spiral Vase - Cyan PLA',
          nozzleDiameter: '0.4',
          nozzleType: 'Hardened Steel',
        ),
      ),
      _DemoState(
        statusLabel: 'RUNNING 34% • 145m left',
        printStatus: const BambuPrintStatus(
          gcodeState: 'RUNNING',
          percent: 34,
          remainingMinutes: 145,
          gcodeFile: 'Engineering_Bracket_v3.3mf',
          layer: 87,
          totalLayers: 256,
          bedTemp: 60.0,
          bedTarget: 60.0,
          nozzleTemp: 255.0,
          nozzleTarget: 255.0,
          chamberTemp: 38.1,
          speedLevel: 3,
          speedMag: 120,
          subtaskName: 'Bracket Assembly - PETG',
          nozzleDiameter: '0.4',
          nozzleType: 'Hardened Steel',
        ),
      ),
      _DemoState(
        statusLabel: 'PAUSED',
        printStatus: const BambuPrintStatus(
          gcodeState: 'PAUSED',
          percent: 12,
          gcodeFile: 'Miniature_Figure_Base.gcode',
          layer: 8,
          totalLayers: 320,
          bedTemp: 55.0,
          bedTarget: 55.0,
          nozzleTemp: 0.0,
          nozzleTarget: 230.0,
          chamberTemp: 28.5,
          speedLevel: 1,
          speedMag: 80,
          subtaskName: 'Miniature Figure - Silk PLA',
          nozzleDiameter: '0.2',
          nozzleType: 'Ruby',
        ),
      ),
      _DemoState(
        statusLabel: 'FINISH 100% • 0m left',
        printStatus: const BambuPrintStatus(
          gcodeState: 'FINISH',
          percent: 100,
          remainingMinutes: 0,
          gcodeFile: 'Cable_Manager_Holder.gcode',
          layer: 156,
          totalLayers: 156,
          bedTemp: 0.0,
          bedTarget: 0.0,
          nozzleTemp: 40.0,
          nozzleTarget: 0.0,
          chamberTemp: 30.0,
          speedLevel: 2,
          speedMag: 100,
          subtaskName: 'Cable Manager - ABS',
          nozzleDiameter: '0.4',
          nozzleType: 'Hardened Steel',
        ),
      ),
    ];
  }

  void _startDemoCycle() {
    _stateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _stateIndex++;
      notifyListeners();
    });
  }

  @override
  Future<String?> setChamberLight(bool on) async => null;

  @override
  Future<String?> setSpeedPercent(int percent) async => null;

  @override
  Future<String?> setSpeedProfile(BambuSpeedProfile profile) async => null;

  @override
  Future<String?> switchCameraSelection(int cameraIndex) async {
    if (cameraIndex >= 0 && cameraIndex < cameraStreams.length) {
      _demoSelectedCameraIndex = cameraIndex;
      _demoCurrentStreamUrl = cameraStreams[cameraIndex].url;
      notifyListeners();
      return _demoCurrentStreamUrl;
    }
    return null;
  }

  @override
  Future<void> disposeController() async {
    _stateTimer?.cancel();
    await super.disposeController();
  }

  /// Helper to get a demo screenshot path for the gallery.
  static Future<String> getDemoScreenshotPath() async {
    final dir = await ScreenshotStorage.primaryDirectory();
    final files = await dir.list().toList();
    final pngFiles = files
        .where((e) => e.path.toLowerCase().endsWith('.png'))
        .map((e) => e.path)
        .toList();
    if (pngFiles.isEmpty) return '';
    return pngFiles[0];
  }
}

class _DemoState {
  final String statusLabel;
  final BambuPrintStatus printStatus;
  const _DemoState({required this.statusLabel, required this.printStatus});
}
