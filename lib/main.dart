import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:boomprint/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/bambu_hms_catalog.g.dart' show bambuHmsCatalogLicense;
import 'package:boomprint/bambu_mqtt.dart';
import 'package:boomprint/log_redaction.dart';
import 'package:boomprint/feature_flags.dart';
import 'package:boomprint/connection_controller.dart';
import 'package:boomprint/settings_manager.dart';
import 'package:boomprint/monitoring_alerts.dart';
import 'package:boomprint/printer_camera_streams.dart';
import 'package:boomprint/printer_firmware.dart';
import 'package:boomprint/sensitive_auth.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'settings_page.dart';
import 'stream_page_widgets.dart';
import 'ftp_browser_page.dart';
import 'screenshot_gallery_page.dart';
import 'screenshot_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'window_drag_controller.dart';

// GTK4 Linux video texture interop mode for local testing. The build helper
// supplies MEDIA_KIT_GTK4_TEXTURE_INTEROP as either direct or egl-image.
const String kLinuxGtk4TextureInteropName = String.fromEnvironment(
  'MEDIA_KIT_GTK4_TEXTURE_INTEROP',
  defaultValue: 'direct',
);
const LinuxGtk4TextureInterop kLinuxGtk4TextureInterop =
    kLinuxGtk4TextureInteropName == 'egl-image'
    ? LinuxGtk4TextureInterop.eglImageBridge
    : LinuxGtk4TextureInterop.directSharedTexture;

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(
    () => Stream.value(
      LicenseEntryWithLineBreaks([
        'bambulan HMS catalog',
      ], bambuHmsCatalogLicense),
    ),
  );
  final cli = _parseCliArgs(args);
  await SettingsManager.loadSettings(
    overridePath: cli.configPath,
    overridePrinterIp: cli.printerIp,
    overrideSpecialCode: cli.accessCode,
    overrideSerialNumber: cli.serialNumber,
    overrideSelectedFormat: cli.format,
    overrideCustomUrl: cli.customUrl,
    overrideGenericRtspUsername: cli.genericRtspUsername,
    overrideGenericRtspPassword: cli.genericRtspPassword,
    overrideGenericRtspPath: cli.genericRtspPath,
    overrideGenericRtspPort: cli.genericRtspPort,
    overrideGenericRtspSecure: cli.genericRtspSecure,
  ); // Load and cache settings
  MediaKit.ensureInitialized();
  // debugPrint(
  //   'media_kit: libmpv client API version ${MediaKit.libmpvClientApiVersion}',
  // );

  runApp(const MyApp());
}

class _CliConfig {
  final String? configPath;
  final String? printerIp;
  final String? accessCode;
  final String? serialNumber;
  final String? format;
  final String? customUrl;
  final String? genericRtspUsername;
  final String? genericRtspPassword;
  final String? genericRtspPath;
  final int? genericRtspPort;
  final bool? genericRtspSecure;

  const _CliConfig({
    this.configPath,
    this.printerIp,
    this.accessCode,
    this.serialNumber,
    this.format,
    this.customUrl,
    this.genericRtspUsername,
    this.genericRtspPassword,
    this.genericRtspPath,
    this.genericRtspPort,
    this.genericRtspSecure,
  });
}

_CliConfig _parseCliArgs(List<String> args) {
  String? configPath;
  String? printerIp;
  String? accessCode;
  String? serialNumber;
  String? format;
  String? customUrl;
  String? genericRtspUsername;
  String? genericRtspPassword;
  String? genericRtspPath;
  int? genericRtspPort;
  bool? genericRtspSecure;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? value;

    if (arg.contains('=')) {
      final parts = arg.split('=');
      if (parts.length >= 2) {
        value = parts.sublist(1).join('=');
      }
    } else if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
      value = args[i + 1];
    }

    switch (arg.split('=').first) {
      case '--config':
        configPath = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--printer-ip':
        printerIp = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--access-code':
        accessCode = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--serial':
        serialNumber = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--format':
        format = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--custom-url':
        customUrl = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--rtsp-username':
        genericRtspUsername = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--rtsp-password':
        genericRtspPassword = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--rtsp-path':
        genericRtspPath = value;
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--rtsp-port':
        if (value != null) {
          genericRtspPort = int.tryParse(value);
        }
        if (value != null && !arg.contains('=')) i++;
        break;
      case '--rtsp-secure':
        genericRtspSecure = value == null
            ? true
            : switch (value.trim().toLowerCase()) {
                '1' || 'true' || 'yes' || 'on' => true,
                '0' || 'false' || 'no' || 'off' => false,
                _ => true,
              };
        if (value != null && !arg.contains('=')) i++;
        break;
      default:
        break;
    }
  }

  return _CliConfig(
    configPath: configPath,
    printerIp: printerIp,
    accessCode: accessCode,
    serialNumber: serialNumber,
    format: format,
    customUrl: customUrl,
    genericRtspUsername: genericRtspUsername,
    genericRtspPassword: genericRtspPassword,
    genericRtspPath: genericRtspPath,
    genericRtspPort: genericRtspPort,
    genericRtspSecure: genericRtspSecure,
  );
}

class MyApp extends StatelessWidget {
  final GlobalKey? rootBoundaryKey;
  final ConnectionController? connectionController;
  final bool demoVideoSurface;

  const MyApp({
    super.key,
    this.rootBoundaryKey,
    this.connectionController,
    this.demoVideoSurface = false,
  });

  @override
  Widget build(BuildContext context) {
    final provider = connectionController == null
        ? ChangeNotifierProvider(
            create: (_) => ConnectionController(),
            child: _buildMaterialApp(),
          )
        : ChangeNotifierProvider.value(
            value: connectionController!,
            child: _buildMaterialApp(),
          );

    if (rootBoundaryKey == null) {
      return provider;
    }

    return RepaintBoundary(key: rootBoundaryKey, child: provider);
  }

  Widget _buildMaterialApp() {
    return MaterialApp(
      title: AppStrings.appDisplayName,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: StreamPage(demoVideoSurface: demoVideoSurface),
      debugShowCheckedModeBanner: false,
    );
  }
}

class StreamPage extends StatefulWidget {
  final bool demoVideoSurface;

  const StreamPage({super.key, this.demoVideoSurface = false});

  @override
  State<StreamPage> createState() => _StreamPageState();
}

bool isAccelSupported({TargetPlatform? platformOverride}) {
  return true;
}

class _StreamPageModel {
  final bool isStreaming;
  final BambuPrintStatus? printStatus;

  const _StreamPageModel({
    required this.isStreaming,
    required this.printStatus,
  });

  @override
  bool operator ==(Object other) {
    return other is _StreamPageModel &&
        other.isStreaming == isStreaming &&
        other.printStatus == printStatus;
  }

  @override
  int get hashCode => Object.hash(isStreaming, printStatus);
}

class _StreamActionsModel {
  final List<PrinterCameraStream> cameraStreams;
  final int selectedCameraIndex;
  final BambuPrintStatus? printStatus;
  final bool mqttConnected;
  final bool? chamberLightOn;
  final bool printCommandBusy;

  const _StreamActionsModel({
    required this.cameraStreams,
    required this.selectedCameraIndex,
    required this.printStatus,
    required this.mqttConnected,
    required this.chamberLightOn,
    required this.printCommandBusy,
  });

  @override
  bool operator ==(Object other) {
    return other is _StreamActionsModel &&
        listEquals(other.cameraStreams, cameraStreams) &&
        other.selectedCameraIndex == selectedCameraIndex &&
        other.printStatus == printStatus &&
        other.mqttConnected == mqttConnected &&
        other.chamberLightOn == chamberLightOn &&
        other.printCommandBusy == printCommandBusy;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(cameraStreams),
    selectedCameraIndex,
    printStatus,
    mqttConnected,
    chamberLightOn,
    printCommandBusy,
  );
}

class _StreamingBodyModel {
  final BambuPrintStatus? printStatus;
  final PrinterFirmwareWarning? firmwareWarning;

  const _StreamingBodyModel({
    required this.printStatus,
    required this.firmwareWarning,
  });

  @override
  bool operator ==(Object other) {
    return other is _StreamingBodyModel &&
        other.printStatus == printStatus &&
        other.firmwareWarning == firmwareWarning;
  }

  @override
  int get hashCode => Object.hash(printStatus, firmwareWarning);
}

class _StreamPageState extends State<StreamPage> with WidgetsBindingObserver {
  late Player player;
  late VideoController controller;
  //final screenshotController = ScreenshotController();
  bool _autoLightWhilePrinting = false;
  bool _wasPrinting = false;
  bool _speedCommandBusy = false;
  bool _hardwareAccelerationEnabled = true;
  bool _hardwareAccelerationCopyEnabled = true;

  // Stall detection & reconnect
  Timer? _stallTimer;
  Duration _lastPosition = Duration.zero;
  DateTime _lastProgressAt = DateTime.now();
  bool _reconnecting = false;
  int _reconnectAttempts = 0;
  static const Duration _stallTimeout = Duration(seconds: 8);
  static const int _maxReconnectAttempts = 6;

  // Buffering / progress & error subscriptions
  bool _buffering = false;
  Duration _bufferPosition = Duration.zero;
  Duration _mediaDuration = Duration.zero;
  double? _bufferFraction; // null = indeterminate
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Duration>? _bufferPosSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<PlayerLog>? _playerLogSub;
  StreamSubscription<Duration>? _positionTraceSub;
  DateTime? _lastErrorToastAt;
  StreamSubscription<bool>? _playingSub;
  bool _showVideoControls = false;
  bool _isPlaying = false;
  String? _videoToastMessage;
  bool _videoToastIsError = false;
  Timer? _controlsHideTimer;
  Timer? _videoToastTimer;
  Timer? _resumeProbeTimer;
  DateTime? _backgroundedAt;
  int _streamViewGeneration = 0;
  ConnectionController? _listeningController;
  BambuPrintStatus? _lastObservedPrintStatus;

  static const double _metricsStripHeight = 80;

  ConnectionController get _connection => context.read<ConnectionController>();

  String _redactLog(String message) => redactLogText(
    message,
    secrets: [
      SettingsManager.settings.specialCode,
      SettingsManager.settings.genericRtspPassword,
    ],
  );

  void _logDebug(String message) => debugPrint(_redactLog(message));

  Future<void> _takeScreenshot({bool useJpeg = false}) async {
    try {
      final format = useJpeg ? 'image/jpeg' : 'image/png';
      final extension = useJpeg ? 'jpg' : 'png';
      final state = player.state;
      _logDebug(
        '[Screenshot] begin playing=${state.playing} buffering=${state.buffering} '
        'completed=${state.completed} position=${state.position} duration=${state.duration} '
        'size=${state.width}x${state.height} playlist=${state.playlist} format=$format',
      );
      // Make sure the video path has produced at least one frame before asking
      // mpv for a screenshot. GTK4 startup is still timing-sensitive here.
      final gateWatch = Stopwatch()..start();
      bool firstFrameReady = false;
      try {
        await controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 5),
        );
        firstFrameReady = true;
      } catch (_) {
        // Fall through and let the screenshot call report the real failure.
      }
      _logDebug(
        '[Screenshot] firstFrameReady=$firstFrameReady elapsed=${gateWatch.elapsedMilliseconds}ms',
      );

      final screenshotData = await player
          .screenshot(format: format, includeLibassSubtitles: false)
          .timeout(const Duration(seconds: 6));
      _logDebug(
        '[Screenshot] captureResult=${screenshotData == null ? 'null' : '${screenshotData.length} bytes'}',
      );

      if (screenshotData != null) {
        // Resolve a platform-appropriate, writable directory
        final screenshotDir = await ScreenshotStorage.primaryDirectory();
        await screenshotDir.create(recursive: true);

        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filename = 'screenshot_$timestamp.$extension';
        final filePath = path.join(screenshotDir.path, filename);

        // Save the screenshot data
        final file = File(filePath);
        await file.writeAsBytes(screenshotData);

        if (mounted) {
          _showVideoToast('Screenshot saved to $filePath', isError: false);
        }
      } else {
        if (mounted) {
          _showVideoToast('Failed to capture screenshot');
        }
      }
    } catch (e) {
      if (mounted) {
        _showVideoToast('Screenshot failed: $e');
      }
    }
  }

  Future<void> _setChamberLight(bool on, {bool showErrors = true}) async {
    final error = await _connection.setChamberLight(on);
    if (error != null && showErrors && mounted) {
      _showVideoToast(error);
    }
  }

  void _toggleChamberLight() {
    final target = !(_connection.chamberLightOn ?? false);
    _setChamberLight(target);
  }

  bool _isPrintingState(String state) {
    switch (state.toUpperCase()) {
      case 'RUNNING':
      case 'PREPARE':
      case 'PAUSED':
        return true;
      default:
        return false;
    }
  }

  void _handleAutoLight(BambuPrintStatus ps, {bool force = false}) {
    final printing = _isPrintingState(ps.gcodeState);
    final shouldEnable =
        _autoLightWhilePrinting && printing && (force || !_wasPrinting);
    _wasPrinting = printing;
    if (shouldEnable && _connection.chamberLightOn != true) {
      _setChamberLight(true, showErrors: false);
    }
  }

  String _lightStatusLabel() {
    return _connection.lightStatusLabel();
  }

  int _currentSpeedPercent(BambuPrintStatus? ps) {
    final mag = ps?.speedMag;
    if (mag != null && mag > 0) {
      return mag;
    }
    return 100;
  }

  BambuSpeedProfile _currentSpeedProfile(BambuPrintStatus? ps) {
    final level = ps?.speedLevel;
    switch (level) {
      case 1:
        return BambuSpeedProfile.silent;
      case 2:
        return BambuSpeedProfile.standard;
      case 3:
        return BambuSpeedProfile.sport;
      case 4:
        return BambuSpeedProfile.ludicrous;
    }

    final percent = _currentSpeedPercent(ps);
    if (percent <= 80) return BambuSpeedProfile.silent;
    if (percent >= 180) return BambuSpeedProfile.ludicrous;
    if (percent >= 130) return BambuSpeedProfile.sport;
    return BambuSpeedProfile.standard;
  }

  Future<void> _setSpeedProfile(BambuSpeedProfile profile) async {
    if (_speedCommandBusy) return;
    setState(() => _speedCommandBusy = true);
    try {
      final error = await _connection.setSpeedProfile(profile);
      if (error != null && mounted) {
        _showVideoToast(error);
      } else {
        _connection.requestPushAll();
      }
    } finally {
      if (mounted) {
        setState(() => _speedCommandBusy = false);
      }
    }
  }

  Future<void> _pauseOrResumePrint() async {
    final paused = isPrintPaused(_connection.lastPrintStatus);
    final error = paused
        ? await _connection.resumePrint()
        : await _connection.pausePrint();
    if (!mounted) return;
    _showVideoToast(
      error ?? (paused ? 'Resume request sent.' : 'Pause request sent.'),
      isError: error != null,
    );
  }

  Future<void> _cancelPrint() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel print?'),
        content: const Text(
          'This stops the current job. The printer will not resume it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep printing'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel print'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await _connection.cancelPrint();
    if (!mounted) return;
    _showVideoToast(error ?? 'Cancel request sent.', isError: error != null);
  }

  Widget _buildSpeedControls({
    required BuildContext context,
    required BambuPrintStatus? printStatus,
    required bool compactLayout,
  }) {
    final currentProfile = _currentSpeedProfile(printStatus);
    final currentPercent = _currentSpeedPercent(printStatus);
    final enabled = _connection.mqttConnected && !_speedCommandBusy;
    final button = IgnorePointer(
      child: OutlinedButton.icon(
        onPressed: enabled ? () {} : null,
        icon: _speedCommandBusy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.speed),
        label: Text('${currentProfile.label} $currentPercent%'),
        style: compactLayout
            ? OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              )
            : null,
      ),
    );

    if (!enabled) {
      return button;
    }

    return PopupMenuButton<BambuSpeedProfile>(
      tooltip: 'Change print speed',
      onSelected: _setSpeedProfile,
      itemBuilder: (context) => BambuSpeedProfile.values
          .map(
            (profile) => PopupMenuItem<BambuSpeedProfile>(
              value: profile,
              child: Row(
                children: [
                  Icon(
                    profile == currentProfile
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('${profile.label} ${profile.fallbackPercent}%'),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      child: button,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    PlayerConfiguration config = PlayerConfiguration(
      logLevel: MPVLogLevel.debug,
    );

    player = Player(configuration: config);
    _listeningController = _connection;
    _listeningController!.addListener(_handleConnectionStateChanged);
    _rebuildVideoController();
    _setupPlayerListeners();
    unawaited(_bootstrapStartup());
    unawaited(MonitoringAlerts.requestAndroidNotificationPermission());
  }

  Future<void> _bootstrapStartup() async {
    await _loadUiSettings();
    await _attemptAutoConnect();
  }

  void _rebuildVideoController() {
    final enabled = _hardwareAccelerationEnabled && isAccelSupported();
    final hwdec = enabled
        ? (_hardwareAccelerationCopyEnabled ? 'auto-copy' : 'auto')
        : 'no';
    _logDebug(
      '[Video] rebuild controller hwAccel=$_hardwareAccelerationEnabled '
      'copy=$_hardwareAccelerationCopyEnabled supported=${isAccelSupported()} '
      'enabled=$enabled hwdec=$hwdec',
    );
    controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: enabled,
        hwdec: hwdec,
        linuxGtk4TextureInterop: kLinuxGtk4TextureInterop,
      ),
    );
  }

  Future<void> _recreatePlayerAndController({
    required bool hardwareAccelerationEnabled,
    required bool hardwareAccelerationCopyEnabled,
    String? reopenUrl,
  }) async {
    final shouldReopen =
        _connection.isStreaming && reopenUrl != null && reopenUrl.isNotEmpty;
    final oldPlayer = player;
    _hardwareAccelerationEnabled = hardwareAccelerationEnabled;
    _hardwareAccelerationCopyEnabled = hardwareAccelerationCopyEnabled;

    _bufferingSub?.cancel();
    _bufferPosSub?.cancel();
    _durationSub?.cancel();
    _errorSub?.cancel();
    _playerLogSub?.cancel();
    _positionTraceSub?.cancel();
    _playingSub?.cancel();
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;

    try {
      await oldPlayer.stop();
    } catch (_) {
      // Ignore cleanup failures; we are replacing the player instance.
    }
    try {
      await oldPlayer.dispose();
    } catch (_) {
      // Ignore cleanup failures; we are replacing the player instance.
    }

    final config = PlayerConfiguration(logLevel: MPVLogLevel.debug);
    player = Player(configuration: config);
    _rebuildVideoController();
    _setupPlayerListeners();
    _streamViewGeneration++;
    if (mounted) {
      setState(() {});
    }

    await WidgetsBinding.instance.endOfFrame;

    if (shouldReopen) {
      try {
        await _openMediaAndEnsurePlaying(reopenUrl);
      } catch (_) {
        // Keep current UI state; existing errors will surface if needed.
      }
    }
  }

  Future<void> _loadUiSettings() async {
    final connection = _connection;
    final settings = await SettingsManager.loadSettings();
    final prevHw = _hardwareAccelerationEnabled;
    final prevCopy = _hardwareAccelerationCopyEnabled;
    final nextHw = settings.hardwareAccelerationEnabled;
    final nextCopy = settings.hardwareAccelerationCopyEnabled;
    _logDebug(
      '[Settings] reload hardwareAccelerationEnabled prev=$prevHw next=$nextHw '
      'copy prev=$prevCopy next=$nextCopy '
      'streaming=${connection.isStreaming} currentStream=${connection.currentStreamUrl}',
    );
    await connection.refreshCameraStreamsFromSettings();
    await WindowChromeController.setLinuxSystemDecorations(
      settings.linuxUseSystemWindowDecorations,
    );
    if (!mounted) return;
    if (prevHw != nextHw || prevCopy != nextCopy) {
      await _recreatePlayerAndController(
        hardwareAccelerationEnabled: nextHw,
        hardwareAccelerationCopyEnabled: nextCopy,
        reopenUrl: connection.currentStreamUrl,
      );
    }
    final nextCameraUrl = connection.cameraStreams.isEmpty
        ? null
        : connection.cameraStreams[connection.selectedCameraIndex].url;
    setState(() {
      _hardwareAccelerationEnabled = nextHw;
      _hardwareAccelerationCopyEnabled = nextCopy;
    });

    if (connection.isStreaming &&
        nextCameraUrl != null &&
        connection.currentStreamUrl != nextCameraUrl) {
      try {
        await _openMediaAndEnsurePlaying(nextCameraUrl);
      } catch (_) {
        // Keep current stream state; existing error handling will surface issues.
      }
    }
  }

  Future<void> _attemptAutoConnect() async {
    final url = await _connection.autoConnectUrl();
    if (!mounted || url == null) return;
    _onConnect(url);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stallTimer?.cancel();
    _bufferingSub?.cancel();
    _bufferPosSub?.cancel();
    _durationSub?.cancel();
    _errorSub?.cancel();
    _playerLogSub?.cancel();
    _positionTraceSub?.cancel();
    _playingSub?.cancel();
    _controlsHideTimer?.cancel();
    _videoToastTimer?.cancel();
    _resumeProbeTimer?.cancel();
    _listeningController?.removeListener(_handleConnectionStateChanged);
    player.dispose();
    unawaited(_connection.disposeController());

    super.dispose();
  }

  void _handleConnectionStateChanged() {
    final current = _connection.lastPrintStatus;
    if (current != null && current != _lastObservedPrintStatus) {
      _notifyForPrintStateTransition(_lastObservedPrintStatus, current);
      _handleAutoLight(current);
      _lastObservedPrintStatus = current;
    } else if (current == null) {
      _lastObservedPrintStatus = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _handleAppResumed();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _handleAppBackgrounded();
        break;
    }
  }

  Future<void> _startStream(String url) async {
    final connection = _connection;
    await connection.startStreaming(url);
    _resetStallMonitor();

    // Start video stream first (independent of MQTT)
    try {
      await _openMediaAndEnsurePlaying(url);
      _startStallMonitor();
    } catch (e) {
      if (mounted) {
        _showVideoToast('Failed to start stream: $e');
        await connection.stopStreaming();
      }
      return;
    }
  }

  Future<void> _stopStream() async {
    _resumeProbeTimer?.cancel();
    _stallTimer?.cancel();
    if (mounted) {
      setState(() {
        _showVideoControls = false;
        _wasPrinting = false;
      });
    }
    await _connection.stopStreaming();
    unawaited(_stopPlayerSafely());
  }

  Future<void> _stopPlayerSafely() async {
    try {
      await player.stop().timeout(const Duration(seconds: 2));
    } catch (e) {
      _logDebug('[Video] stop timed out or failed: $e');
    }
  }

  void _handleAppBackgrounded() {
    _resumeProbeTimer?.cancel();
    _stallTimer?.cancel();
    _backgroundedAt ??= DateTime.now();
    // Do not query the native player while Android is transitioning it to the
    // background; MPV may already be shutting down its decoder.
    _lastPosition = Duration.zero;
    _lastProgressAt = DateTime.now();
  }

  Future<void> _handleAppResumed() async {
    final connection = _connection;
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (!connection.isStreaming || connection.currentStreamUrl == null) {
      return;
    }

    final url = connection.currentStreamUrl!;

    // Android may keep the Dart isolate alive while reclaiming the native
    // decoder/player during a long background suspension. Reusing that player
    // can crash in native code, so replace it before reopening the stream.
    final longSuspension =
        backgroundedAt != null &&
        DateTime.now().difference(backgroundedAt) >=
            const Duration(seconds: 15);
    if (Platform.isAndroid && longSuspension) {
      try {
        await _recreatePlayerAndController(
          hardwareAccelerationEnabled: _hardwareAccelerationEnabled,
          hardwareAccelerationCopyEnabled: _hardwareAccelerationCopyEnabled,
          reopenUrl: url,
        );
      } catch (error) {
        _logDebug('[Video] long-resume player recovery failed: $error');
      }
      unawaited(connection.reconnectMqttIfNeeded());
      return;
    }

    _lastPosition = player.state.position;
    _lastProgressAt = DateTime.now();

    try {
      await player.play();
    } catch (_) {
      // Resume probing below will force a reconnect if playback is still stale.
    }

    _startStallMonitor();
    _scheduleResumeProbe(url);

    unawaited(connection.reconnectMqttIfNeeded());
  }

  void _scheduleResumeProbe(String url) {
    _resumeProbeTimer?.cancel();
    final probePosition = player.state.position;
    _resumeProbeTimer = Timer(const Duration(seconds: 2), () {
      final connection = _connection;
      if (!mounted ||
          !connection.isStreaming ||
          connection.currentStreamUrl != url) {
        return;
      }
      final state = player.state;
      final advanced = state.position > probePosition;
      if (state.playing && advanced) {
        return;
      }
      _attemptReconnect(
        reason: 'resume recovery',
        immediate: true,
        resetAttempts: true,
      );
    });
  }

  void _notifyForPrintStateTransition(
    BambuPrintStatus? previous,
    BambuPrintStatus current,
  ) {
    if (previous == null) {
      return;
    }

    final previousState = previous.gcodeState.trim().toUpperCase();
    final currentState = current.gcodeState.trim().toUpperCase();
    if (currentState.isEmpty || previousState == currentState) {
      return;
    }

    if (currentState == 'PAUSED') {
      _emitMonitoringAttention(
        title: 'Print paused',
        body: _monitoringBody(
          current,
          fallback: 'The current print is paused.',
        ),
      );
      return;
    }

    if (_isErrorPrintState(currentState)) {
      _emitMonitoringAttention(
        title: 'Printer needs attention',
        body: _monitoringBody(
          current,
          fallback: 'Printer reported state $currentState.',
        ),
      );
      return;
    }

    if (_isSuccessPrintState(currentState) &&
        _isActivePrintState(previousState)) {
      _emitMonitoringSuccess(
        title: 'Print finished',
        body: _monitoringBody(
          current,
          fallback: 'The monitored print completed successfully.',
        ),
      );
    }
  }

  bool _isActivePrintState(String state) {
    switch (state) {
      case 'RUNNING':
      case 'PREPARE':
      case 'PAUSED':
        return true;
      default:
        return false;
    }
  }

  bool _isSuccessPrintState(String state) {
    switch (state) {
      case 'FINISH':
      case 'FINISHED':
      case 'COMPLETE':
      case 'COMPLETED':
      case 'SUCCESS':
        return true;
      default:
        return false;
    }
  }

  bool _isErrorPrintState(String state) {
    switch (state) {
      case 'FAILED':
      case 'FAIL':
      case 'ERROR':
      case 'EXCEPTION':
      case 'CANCELED':
      case 'CANCELLED':
      case 'ABORTED':
      case 'STOPPED':
      case 'ALARM':
        return true;
      default:
        return state.contains('ERROR') ||
            state.contains('FAIL') ||
            state.contains('EXCEPTION');
    }
  }

  String _monitoringBody(BambuPrintStatus status, {required String fallback}) {
    final name = status.subtaskName ?? status.gcodeFile;
    if (name != null && name.trim().isNotEmpty) {
      return name.trim();
    }
    return fallback;
  }

  void _emitMonitoringAttention({required String title, required String body}) {
    if (Platform.isAndroid) {
      unawaited(
        MonitoringAlerts.showAndroidNotification(
          title: title,
          body: body,
          success: false,
        ),
      );
      return;
    }
    // Desktop alerts use an attention sound only.
    unawaited(MonitoringAlerts.playAttentionSound());
  }

  void _emitMonitoringSuccess({required String title, required String body}) {
    if (Platform.isAndroid) {
      unawaited(
        MonitoringAlerts.showAndroidNotification(
          title: title,
          body: body,
          success: true,
        ),
      );
      return;
    }
    // Desktop alerts use a completion sound only.
    unawaited(MonitoringAlerts.playSuccessSound());
  }

  void _setupPlayerListeners() {
    // Cancel existing subscriptions if any
    _bufferingSub?.cancel();
    _bufferPosSub?.cancel();
    _durationSub?.cancel();
    _errorSub?.cancel();
    _playingSub?.cancel();

    _bufferingSub = player.stream.buffering.listen((b) {
      _logDebug(
        '[VideoState] buffering=$b playing=${player.state.playing} '
        'position=${player.state.position} size=${player.state.width}x${player.state.height}',
      );
      if (!mounted) return;
      setState(() {
        _buffering = b;
      });
    });
    _bufferPosSub = player.stream.buffer.listen((d) {
      _bufferPosition = d;
      _recomputeBufferFraction();
    });
    _durationSub = player.stream.duration.listen((d) {
      _mediaDuration = d;
      _recomputeBufferFraction();
    });
    _errorSub = player.stream.error.listen((msg) {
      _logDebug('[VideoState] error=$msg');
      // Throttle error toasts to avoid spam
      final now = DateTime.now();
      if (_lastErrorToastAt == null ||
          now.difference(_lastErrorToastAt!) > const Duration(seconds: 5)) {
        _lastErrorToastAt = now;
        if (mounted) {
          final userMsg = _friendlyError(msg);
          _showVideoToast(userMsg);
        }
      }
      _attemptReconnect(reason: 'error: $msg');
    });
    _playingSub = player.stream.playing.listen((playing) {
      _logDebug(
        '[VideoState] playing=$playing buffering=${player.state.buffering} '
        'position=${player.state.position} completed=${player.state.completed}',
      );
      if (!mounted) return;
      setState(() {
        _isPlaying = playing;
      });
    });
    _positionTraceSub = player.stream.position.listen((position) {
      if (position == Duration.zero || position.inSeconds % 5 == 0) {
        _logDebug(
          '[VideoState] position=$position playing=${player.state.playing} '
          'buffering=${player.state.buffering}',
        );
      }
    });
    _playerLogSub = player.stream.log.listen((log) {
      if (const {
        'cplayer',
        'demux',
        'ffmpeg',
        'cache',
        'vd',
        'vo',
      }.contains(log.prefix)) {
        _logDebug(
          '[VideoMpv] level=${log.level} prefix=${log.prefix} text=${log.text}',
        );
      }
    });
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() {
      _showVideoControls = true;
    });
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _showVideoControls = false;
      });
    });
  }

  void _showVideoToast(
    String message, {
    bool isError = true,
    Duration duration = const Duration(seconds: 3),
  }) {
    if (!mounted) return;
    _videoToastTimer?.cancel();
    setState(() {
      _videoToastMessage = _redactLog(message);
      _videoToastIsError = isError;
    });
    _videoToastTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() {
        _videoToastMessage = null;
      });
    });
  }

  void _recomputeBufferFraction() {
    if (!mounted) return;
    if (_mediaDuration.inMilliseconds > 0) {
      final f = _bufferPosition.inMilliseconds / _mediaDuration.inMilliseconds;
      setState(() {
        _bufferFraction = f.clamp(0.0, 1.0);
      });
    } else {
      setState(() {
        _bufferFraction = null; // indeterminate
      });
    }
  }

  String _friendlyError(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('401') || m.contains('unauthorized')) {
      return 'Stream error: Unauthorized (check special code / credentials).';
    }
    if (m.contains('403') || m.contains('forbidden')) {
      return 'Stream error: Access forbidden (printer or network blocked).';
    }
    if (m.contains('timed out') || m.contains('timeout')) {
      return 'Stream error: Connection timed out (printer offline or unreachable).';
    }
    if (m.contains('host') && m.contains('not') && m.contains('resolve')) {
      return 'Stream error: Host not found (check printer IP).';
    }
    if (m.contains('connection refused') || m.contains('refused')) {
      return 'Stream error: Connection refused (service not available).';
    }
    if (m.contains('tls') || m.contains('ssl') || m.contains('certificate')) {
      return 'Stream error: TLS/SSL problem (certificate or protocol).';
    }
    return 'Stream error: $raw';
  }

  void _resetStallMonitor() {
    _lastPosition = Duration.zero;
    _lastProgressAt = DateTime.now();
    _reconnecting = false;
    _reconnectAttempts = 0;
  }

  void _startStallMonitor() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final connection = _connection;
      if (!connection.isStreaming || connection.currentStreamUrl == null) {
        return;
      }
      try {
        final state = player.state;
        // Only consider stalls while playing & not buffering.
        if (!state.playing || state.buffering) return;

        final position = state.position;
        // Detect forward progress.
        if (position > _lastPosition) {
          _lastPosition = position;
          _lastProgressAt = DateTime.now();
          return;
        }

        // No progress for too long -> reconnect
        final stalledFor = DateTime.now().difference(_lastProgressAt);
        if (stalledFor >= _stallTimeout) {
          _attemptReconnect(reason: 'stalled ${stalledFor.inSeconds}s');
        }
      } catch (error) {
        _logDebug('[Video] stall monitor lost native player: $error');
        timer.cancel();
        _attemptReconnect(reason: 'native player unavailable', immediate: true);
      }
    });

    // Error events are handled in _setupPlayerListeners.
  }

  void _attemptReconnect({
    required String reason,
    bool immediate = false,
    bool resetAttempts = false,
  }) {
    final connection = _connection;
    if (_reconnecting || connection.currentStreamUrl == null) return;
    if (resetAttempts) {
      _reconnectAttempts = 0;
    }
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      // Give up for now.
      if (mounted) {
        _showVideoToast('Stream lost ($reason). Giving up.');
      }
      return;
    }
    _reconnecting = true;
    final attempt = _reconnectAttempts + 1;
    // Exponential backoff: 2, 4, 8, 16... seconds (capped at 30s)
    final delaySeconds = immediate
        ? 0
        : (2 << (_reconnectAttempts)).clamp(2, 30);

    if (mounted && !immediate) {
      _showVideoToast(
        'Reconnecting (attempt $attempt) in ${delaySeconds}s...',
        isError: false,
      );
    }

    Future.delayed(Duration(seconds: delaySeconds), () async {
      if (!connection.isStreaming || connection.currentStreamUrl == null) {
        _reconnecting = false;
        return;
      }
      try {
        await _openMediaAndEnsurePlaying(connection.currentStreamUrl!);
        _reconnectAttempts = 0;
        _reconnecting = false;
        _lastPosition = Duration.zero;
        _lastProgressAt = DateTime.now();
        if (mounted) {
          _showVideoToast('Reconnected to stream.', isError: false);
        }
      } catch (e) {
        _reconnectAttempts++;
        _reconnecting = false;
        if (mounted) {
          _showVideoToast('Reconnect failed: $e');
        }
      }
    });
  }

  Future<void> _openMediaAndEnsurePlaying(String url) async {
    _logDebug(
      '[VideoOpen] begin url=$url statePlaying=${player.state.playing} '
      'buffering=${player.state.buffering}',
    );
    await player.open(Media(url), play: true);
    _logDebug(
      '[VideoOpen] complete statePlaying=${player.state.playing} '
      'buffering=${player.state.buffering} position=${player.state.position} '
      'size=${player.state.width}x${player.state.height}',
    );
  }

  Future<void> _switchCamera(int cameraIndex) async {
    final connection = _connection;
    if (!connection.isStreaming ||
        cameraIndex < 0 ||
        cameraIndex >= connection.cameraStreams.length ||
        cameraIndex == connection.selectedCameraIndex) {
      return;
    }
    final nextStream = await connection.switchCameraSelection(cameraIndex);
    if (nextStream == null) return;
    _resetStallMonitor();
    try {
      await _openMediaAndEnsurePlaying(nextStream);
      _startStallMonitor();
    } catch (e) {
      if (mounted) {
        _showVideoToast('Camera switch failed: $e');
      }
    }
  }

  Future<void> _openSettings() async {
    if (SensitiveAuth.isAndroid) {
      final authenticated = await SensitiveAuth.authenticate(
        reason: 'Authenticate to open printer settings.',
      );
      if (!authenticated) {
        if (mounted) {
          _showVideoToast('Settings access was not approved.');
        }
        return;
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(onConnect: _onConnect),
      ),
    );
    await _loadUiSettings();
  }

  void _onConnect(String url) {
    _startStream(url);
  }

  bool _isMobileLandscape(BuildContext context) {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return false;
    }
    return MediaQuery.of(context).orientation == Orientation.landscape;
  }

  Widget _buildVideoSurface({required bool compactLayout}) {
    final printStatus = context.select<ConnectionController, BambuPrintStatus?>(
      (connection) => connection.lastPrintStatus,
    );
    return MouseRegion(
      onEnter: (_) {
        setState(() {
          _showVideoControls = true;
        });
        _controlsHideTimer?.cancel();
      },
      onExit: (_) {
        setState(() {
          _showVideoControls = false;
        });
        _controlsHideTimer?.cancel();
      },
      child: GestureDetector(
        onTap: _showControlsTemporarily,
        child: Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return widget.demoVideoSurface
                      ? const _DemoVideoPreview()
                      : Video(controller: controller);
                },
              ),
            ),
            if (printStatus != null)
              Positioned(
                left: 12,
                top: 12,
                child: PrintOverlayStatus(status: printStatus),
              ),
            if (_videoToastMessage != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: IgnorePointer(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: (_videoToastIsError
                              ? Colors.black.withOpacity(0.78)
                              : Colors.blueGrey.withOpacity(0.82)),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _videoToastIsError
                                ? Colors.redAccent.withOpacity(0.5)
                                : Colors.white.withOpacity(0.18),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Text(
                            _videoToastMessage!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_showVideoControls,
                child: AnimatedOpacity(
                  opacity: _showVideoControls ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    color: Colors.black.withOpacity(0.2),
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(48),
                        ),
                        child: IconButton(
                          iconSize: compactLayout ? 44 : 56,
                          color: Colors.white,
                          icon: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                          onPressed: () {
                            if (_isPlaying) {
                              player.pause();
                            } else {
                              player.play();
                            }
                            _showControlsTemporarily();
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamActions({required bool compactLayout}) {
    final model = context.select<ConnectionController, _StreamActionsModel>(
      (connection) => _StreamActionsModel(
        cameraStreams: connection.cameraStreams,
        selectedCameraIndex: connection.selectedCameraIndex,
        printStatus: connection.lastPrintStatus,
        mqttConnected: connection.mqttConnected,
        chamberLightOn: connection.chamberLightOn,
        printCommandBusy: connection.printCommandBusy,
      ),
    );
    final hasMultipleCameras = model.cameraStreams.length > 1;
    final printStatus = model.printStatus;
    final printControls = PrintControlButtons(
      status: printStatus,
      mqttConnected: model.mqttConnected,
      busy: model.printCommandBusy,
      onPause: _pauseOrResumePrint,
      onResume: _pauseOrResumePrint,
      onCancel: _cancelPrint,
    );
    final lightButton = OutlinedButton.icon(
      onPressed: (model.mqttConnected || model.chamberLightOn != null)
          ? _toggleChamberLight
          : null,
      icon: Icon(
        model.chamberLightOn == true
            ? Icons.lightbulb
            : Icons.lightbulb_outline,
      ),
      label: Text(_lightStatusLabel()),
    );
    if (compactLayout) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasMultipleCameras) ...[
            Row(
              children: [
                const Text('Camera'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<int>(
                    value: model.selectedCameraIndex,
                    isExpanded: true,
                    items: model.cameraStreams
                        .map(
                          (stream) => DropdownMenuItem<int>(
                            value: stream.index,
                            child: Text(stream.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      _switchCamera(value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          ElevatedButton.icon(
            onPressed: _stopStream,
            icon: const Icon(Icons.stop),
            label: const Text('Disconnect'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _takeScreenshot,
            icon: const Icon(Icons.camera_alt),
            label: const Text('Screenshot'),
          ),
          const SizedBox(height: 8),
          lightButton,
          if (isPrintActive(printStatus)) ...[
            const SizedBox(height: 8),
            printControls,
          ],
          if (FeatureFlags.speedControlEnabled) ...[
            const SizedBox(height: 8),
            _buildSpeedControls(
              context: context,
              printStatus: printStatus,
              compactLayout: compactLayout,
            ),
          ],
        ],
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (hasMultipleCameras)
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withOpacity(0.22),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Camera'),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: model.selectedCameraIndex,
                    underline: const SizedBox.shrink(),
                    items: model.cameraStreams
                        .map(
                          (stream) => DropdownMenuItem<int>(
                            value: stream.index,
                            child: Text(stream.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      _switchCamera(value);
                    },
                  ),
                ],
              ),
            ),
          ),
        ElevatedButton.icon(
          onPressed: _stopStream,
          icon: const Icon(Icons.stop),
          label: const Text('Disconnect'),
        ),
        OutlinedButton.icon(
          onPressed: _takeScreenshot,
          icon: const Icon(Icons.camera_alt),
          label: const Text('Screenshot'),
        ),
        lightButton,
        printControls,
        if (FeatureFlags.speedControlEnabled)
          _buildSpeedControls(
            context: context,
            printStatus: printStatus,
            compactLayout: compactLayout,
          ),
      ],
    );
  }

  Widget _buildStreamingBody(
    BuildContext context, {
    required bool compactLayout,
  }) {
    final model = context.select<ConnectionController, _StreamingBodyModel>(
      (connection) => _StreamingBodyModel(
        printStatus: connection.lastPrintStatus,
        firmwareWarning: connection.firmwareWarning,
      ),
    );
    final firmwareBanner = model.firmwareWarning == null
        ? null
        : FirmwareWarningBanner(
            warning: model.firmwareWarning!,
            onOpenHelp: () {
              final links = model.firmwareWarning!.helpEntry.links;
              if (links.isNotEmpty) {
                _openExternalUrl(links.first.url);
              }
            },
          );
    final faultBanner = model.printStatus == null
        ? null
        : PrinterFaultBanner(status: model.printStatus!);
    final videoPane = Column(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compactLayout ? 8 : 0,
              compactLayout ? 8 : 0,
              compactLayout ? 4 : 0,
              compactLayout ? 8 : 0,
            ),
            child: _buildVideoSurface(compactLayout: compactLayout),
          ),
        ),
        if (_bufferFraction != null || _buffering)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: compactLayout ? 8 : 8),
            child: LinearProgressIndicator(
              value: _bufferFraction,
              minHeight: 4,
            ),
          ),
        if (!compactLayout)
          SizedBox(
            height: _metricsStripHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: ClipRect(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: model.printStatus == null
                        ? const SizedBox.shrink()
                        : MetricsPanel(
                            key: ValueKey<String>(
                              model.printStatus!.gcodeState.isEmpty
                                  ? 'metrics'
                                  : model.printStatus!.gcodeState,
                            ),
                            ps: model.printStatus!,
                          ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (compactLayout) {
      return Column(
        children: [
          if (firmwareBanner != null) firmwareBanner,
          if (faultBanner != null) faultBanner,
          Expanded(
            child: Row(
              children: [
                Expanded(child: videoPane),
                SizedBox(
                  width: 248,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (model.printStatus != null)
                              MetricsPanel(ps: model.printStatus!),
                            if (model.printStatus != null)
                              FilamentStatusPanel(status: model.printStatus!),
                            if (model.printStatus != null)
                              const SizedBox(height: 12),
                            _buildStreamActions(compactLayout: true),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (firmwareBanner != null) firmwareBanner,
        if (faultBanner != null) faultBanner,
        Expanded(child: videoPane),
        if (model.printStatus != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: FilamentStatusPanel(status: model.printStatus!),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: _buildStreamActions(compactLayout: false),
        ),
      ],
    );
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      _showVideoToast('Could not open link: $url');
    }
  }

  List<Widget> _buildHeaderActions(BuildContext context) {
    void openFiles() {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const FtpBrowserPage()));
    }

    void openScreenshots() {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ScreenshotGalleryPage()));
    }

    const compactHeaderThreshold = 980.0;
    final width = MediaQuery.of(context).size.width;
    final useOverflowMenu = width < compactHeaderThreshold;

    if (useOverflowMenu) {
      return [
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.menu),
          onSelected: (value) {
            switch (value) {
              case 'files':
                openFiles();
                break;
              case 'screenshots':
                openScreenshots();
                break;
              case 'settings':
                _openSettings();
                break;
            }
          },
          itemBuilder: (context) => [
            if (FeatureFlags.ftpBrowserEnabled)
              const PopupMenuItem<String>(value: 'files', child: Text('Files')),
            const PopupMenuItem<String>(
              value: 'screenshots',
              child: Text('Screenshots'),
            ),
            const PopupMenuItem<String>(
              value: 'settings',
              child: Text('Settings'),
            ),
          ],
        ),
      ];
    }

    return [
      if (FeatureFlags.ftpBrowserEnabled)
        IconButton(
          tooltip: 'Files',
          icon: const Icon(Icons.folder_open),
          onPressed: openFiles,
        ),
      IconButton(
        tooltip: 'Screenshots',
        icon: const Icon(Icons.photo_library),
        onPressed: openScreenshots,
      ),
      IconButton(
        tooltip: 'Settings',
        icon: const Icon(Icons.settings),
        onPressed: _openSettings,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final model = context.select<ConnectionController, _StreamPageModel>(
      (connection) => _StreamPageModel(
        isStreaming: connection.isStreaming,
        printStatus: connection.lastPrintStatus,
      ),
    );
    final titleSummary = buildTitleSummary(model.printStatus);
    final compactLandscape = _isMobileLandscape(context);

    return FramelessWindowResizeFrame(
      child: KeyedSubtree(
        key: ValueKey(_streamViewGeneration),
        child: Scaffold(
          appBar: WindowChromeHeader(
            title: const Text(AppStrings.appDisplayName),
            subtitle: titleSummary == null
                ? null
                : Text(
                    titleSummary,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
            actions: _buildHeaderActions(context),
          ),
          body: model.isStreaming
              ? _buildStreamingBody(context, compactLayout: compactLandscape)
              : DisconnectedBody(
                  onOpenSettings: _openSettings,
                  onConnect: (url) async => _onConnect(url),
                ),
        ),
      ),
    );
  }
}

class _DemoVideoPreview extends StatelessWidget {
  const _DemoVideoPreview();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(color: Color(0xFF101214)),
      child: Stack(
        fit: StackFit.expand,
        children: [_DemoVideoScene(), _DemoVideoVignette()],
      ),
    );
  }
}

class _DemoVideoScene extends StatelessWidget {
  const _DemoVideoScene();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DemoVideoScenePainter());
  }
}

class _DemoVideoVignette extends StatelessWidget {
  const _DemoVideoVignette();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [Colors.transparent, Colors.black.withOpacity(0.35)],
            radius: 1.15,
          ),
        ),
      ),
    );
  }
}

class _DemoVideoScenePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF15181C), Color(0xFF0B0D10)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bgPaint);

    final center = size.center(Offset.zero);

    final bedRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(center.dx, size.height * 0.70),
        width: size.width * 0.62,
        height: size.height * 0.20,
      ),
      const Radius.circular(14),
    );
    canvas.drawRRect(
      bedRect,
      Paint()..color = const Color(0xFF70777F).withOpacity(0.9),
    );

    canvas.drawRRect(
      bedRect.deflate(10),
      Paint()..color = const Color(0xFFB2B7BD).withOpacity(0.38),
    );

    final framePaint = Paint()
      ..color = const Color(0xFF0A0B0D)
      ..strokeWidth = size.width * 0.02
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(size.width * 0.16, size.height * 0.12),
      Offset(size.width * 0.16, size.height * 0.82),
      framePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.84, size.height * 0.12),
      Offset(size.width * 0.84, size.height * 0.82),
      framePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.16, size.height * 0.12),
      Offset(size.width * 0.84, size.height * 0.12),
      framePaint,
    );

    final carriage = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.46, size.height * 0.33),
        width: size.width * 0.18,
        height: size.height * 0.18,
      ),
      const Radius.circular(10),
    );
    canvas.drawRRect(
      carriage,
      Paint()..color = const Color(0xFFE7E9ED).withOpacity(0.88),
    );
    canvas.drawCircle(
      Offset(size.width * 0.46, size.height * 0.33),
      size.shortestSide * 0.035,
      Paint()..color = const Color(0xFF090A0C),
    );

    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width * 0.52, size.height * 0.45),
        width: size.width * 0.40,
        height: size.height * 0.08,
      ),
      Paint()..color = const Color(0xFF2A2D31).withOpacity(0.75),
    );

    final accentPaint = Paint()
      ..color = const Color(0xFF9EB4CF).withOpacity(0.35)
      ..strokeWidth = size.width * 0.01
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.22, size.height * 0.52),
      Offset(size.width * 0.78, size.height * 0.52),
      accentPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.24, size.height * 0.58),
      Offset(size.width * 0.76, size.height * 0.58),
      accentPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _DemoVideoScenePainter oldDelegate) => false;
}
