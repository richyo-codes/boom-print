import 'dart:async';
import 'dart:io';

import 'package:boomprint/printer_url_formats.dart';
import 'package:boomprint/settings_manager.dart';

enum PortCheckStatus {
  reachable,
  timedOut,
  connectionRefused,
  networkUnreachable,
  invalidTarget,
  skipped,
  unknownFailure,
}

class PortCheckResult {
  final String label;
  final String host;
  final int port;
  final bool required;
  final PortCheckStatus status;
  final String message;
  final Duration elapsed;

  const PortCheckResult({
    required this.label,
    required this.host,
    required this.port,
    required this.required,
    required this.status,
    required this.message,
    required this.elapsed,
  });

  bool get isReachable => status == PortCheckStatus.reachable;
  bool get isSkipped => status == PortCheckStatus.skipped;

  String get endpoint => '$host:$port';
}

class ConnectionPreflightSummary {
  final String streamUrl;
  final List<PortCheckResult> results;

  const ConnectionPreflightSummary({
    required this.streamUrl,
    required this.results,
  });

  Iterable<PortCheckResult> get requiredFailures => results.where(
    (result) => result.required && !result.isReachable && !result.isSkipped,
  );

  Iterable<PortCheckResult> get optionalFailures => results.where(
    (result) => !result.required && !result.isReachable && !result.isSkipped,
  );

  bool get hasRequiredFailures => requiredFailures.isNotEmpty;

  String get summaryLine {
    final requiredCount = requiredFailures.length;
    final optionalCount = optionalFailures.length;
    if (requiredCount == 0 && optionalCount == 0) {
      return 'All checked ports are reachable.';
    }
    if (requiredCount > 0 && optionalCount == 0) {
      return 'Required ports failed: ${requiredFailures.map((r) => r.label).join(', ')}';
    }
    if (requiredCount == 0 && optionalCount > 0) {
      return 'Optional ports unavailable: ${optionalFailures.map((r) => r.label).join(', ')}';
    }
    return 'Required ports failed: ${requiredFailures.map((r) => r.label).join(', ')}. Optional ports unavailable: ${optionalFailures.map((r) => r.label).join(', ')}';
  }
}

class ConnectionPreflight {
  static String buildStreamUrl(AppSettings settings, {int? cameraIndex}) {
    switch (settings.selectedFormat) {
      case PrinterUrlType.custom:
        return settings.customUrl.trim();
      case PrinterUrlType.genericRtsp:
        final host = settings.printerIp.trim();
        final port = settings.genericRtspPort;
        final rawPath = settings.genericRtspPath.trim().isEmpty
            ? '/stream'
            : settings.genericRtspPath.trim();
        final normalizedPath = rawPath.startsWith('/') ? rawPath : '/$rawPath';
        final scheme = settings.genericRtspSecure ? 'rtsps' : 'rtsp';
        final user = settings.genericRtspUsername.trim();
        final pass = settings.genericRtspPassword;
        final userInfo = user.isEmpty
            ? ''
            : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@';
        return '$scheme://$userInfo$host:$port$normalizedPath';
      case PrinterUrlType.bambuX1C:
      case PrinterUrlType.bambuP1S:
      case PrinterUrlType.bambuX2D:
      case PrinterUrlType.bambuH2C:
      case PrinterUrlType.bambuH2D:
      case PrinterUrlType.bambuH2S:
        final cameraNumber = cameraIndex ?? (settings.selectedCameraIndex + 1);
        return 'rtsps://bblp:${settings.specialCode}@${settings.printerIp}:322/streaming/live/$cameraNumber';
    }
  }

  static Future<ConnectionPreflightSummary> run({
    required AppSettings settings,
    String? streamUrl,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final resolvedStreamUrl = (streamUrl ?? buildStreamUrl(settings)).trim();

    final streamTarget = _parseTarget(
      resolvedStreamUrl,
      fallbackHost: settings.printerIp.trim(),
      fallbackPort: _defaultStreamPort(settings),
    );
    final streamCheck = _checkTarget(
      label: 'Stream',
      target: streamTarget,
      required: true,
      timeout: timeout,
    );

    final controlHost = settings.printerIp.trim().isNotEmpty
        ? settings.printerIp.trim()
        : streamTarget?.host ?? '';
    if (controlHost.isEmpty) {
      final streamResult = await streamCheck;
      return ConnectionPreflightSummary(
        streamUrl: resolvedStreamUrl,
        results: [
          streamResult,
          PortCheckResult(
            label: 'MQTT',
            host: '',
            port: 8883,
            required: _mqttIsRequired(settings),
            status: PortCheckStatus.skipped,
            message: 'No printer host configured.',
            elapsed: Duration.zero,
          ),
          PortCheckResult(
            label: 'FTP/FTPS',
            host: '',
            port: 990,
            required: false,
            status: PortCheckStatus.skipped,
            message: 'No printer host configured.',
            elapsed: Duration.zero,
          ),
        ],
      );
    }

    final results = await Future.wait([
      streamCheck,
      _checkTarget(
        label: 'MQTT',
        target: _PortTarget(
          host: controlHost,
          port: 8883,
          description: 'MQTT telemetry/control',
        ),
        required: _mqttIsRequired(settings),
        timeout: timeout,
      ),
      _checkTarget(
        label: 'FTP/FTPS',
        target: _PortTarget(
          host: controlHost,
          port: 990,
          description: 'FTP/FTPS browser/upload',
        ),
        required: false,
        timeout: timeout,
      ),
    ]);

    return ConnectionPreflightSummary(
      streamUrl: resolvedStreamUrl,
      results: results,
    );
  }

  static bool _mqttIsRequired(AppSettings settings) {
    switch (settings.selectedFormat) {
      case PrinterUrlType.bambuX1C:
      case PrinterUrlType.bambuP1S:
      case PrinterUrlType.bambuX2D:
      case PrinterUrlType.bambuH2C:
      case PrinterUrlType.bambuH2D:
      case PrinterUrlType.bambuH2S:
        return true;
      case PrinterUrlType.genericRtsp:
      case PrinterUrlType.custom:
        return false;
    }
  }

  static int _defaultStreamPort(AppSettings settings) {
    switch (settings.selectedFormat) {
      case PrinterUrlType.bambuX1C:
      case PrinterUrlType.bambuP1S:
      case PrinterUrlType.bambuX2D:
      case PrinterUrlType.bambuH2C:
      case PrinterUrlType.bambuH2D:
      case PrinterUrlType.bambuH2S:
        return 322;
      case PrinterUrlType.genericRtsp:
        return settings.genericRtspPort;
      case PrinterUrlType.custom:
        return 0;
    }
  }

  static _PortTarget? _parseTarget(
    String raw, {
    required String fallbackHost,
    required int fallbackPort,
  }) {
    final text = raw.trim();
    if (text.isEmpty) {
      if (fallbackHost.isEmpty || fallbackPort <= 0) {
        return null;
      }
      return _PortTarget(
        host: fallbackHost,
        port: fallbackPort,
        description: 'stream',
      );
    }

    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.trim().isEmpty) {
      if (fallbackHost.isEmpty || fallbackPort <= 0) {
        return null;
      }
      return _PortTarget(
        host: fallbackHost,
        port: fallbackPort,
        description: 'stream',
      );
    }

    final port = uri.hasPort
        ? uri.port
        : switch (uri.scheme.toLowerCase()) {
            'rtsp' => 554,
            'rtsps' => 322,
            _ => fallbackPort,
          };

    if (port <= 0) {
      return null;
    }

    return _PortTarget(host: uri.host, port: port, description: 'stream');
  }

  static Future<PortCheckResult> _checkTarget({
    required String label,
    required _PortTarget? target,
    required bool required,
    required Duration timeout,
  }) async {
    if (target == null) {
      return PortCheckResult(
        label: label,
        host: '',
        port: 0,
        required: required,
        status: PortCheckStatus.invalidTarget,
        message: 'Unable to determine a target host/port.',
        elapsed: Duration.zero,
      );
    }

    final started = DateTime.now();
    try {
      final socket = await Socket.connect(
        target.host,
        target.port,
      ).timeout(timeout);
      socket.destroy();
      return PortCheckResult(
        label: label,
        host: target.host,
        port: target.port,
        required: required,
        status: PortCheckStatus.reachable,
        message: '${target.description} reachable.',
        elapsed: DateTime.now().difference(started),
      );
    } on TimeoutException {
      return PortCheckResult(
        label: label,
        host: target.host,
        port: target.port,
        required: required,
        status: PortCheckStatus.timedOut,
        message: '${target.description} timed out after ${timeout.inSeconds}s.',
        elapsed: DateTime.now().difference(started),
      );
    } on SocketException catch (e) {
      final message = e.message.toLowerCase();
      final status = _classifySocketException(message);
      return PortCheckResult(
        label: label,
        host: target.host,
        port: target.port,
        required: required,
        status: status,
        message: _describeSocketException(target.description, e.message),
        elapsed: DateTime.now().difference(started),
      );
    } catch (e) {
      return PortCheckResult(
        label: label,
        host: target.host,
        port: target.port,
        required: required,
        status: PortCheckStatus.unknownFailure,
        message: '${target.description} check failed: $e',
        elapsed: DateTime.now().difference(started),
      );
    }
  }

  static PortCheckStatus _classifySocketException(String message) {
    if (message.contains('refused')) {
      return PortCheckStatus.connectionRefused;
    }
    if (message.contains('timed out') || message.contains('timeout')) {
      return PortCheckStatus.timedOut;
    }
    if (message.contains('unreachable') ||
        message.contains('network is unreachable') ||
        message.contains('host is unreachable')) {
      return PortCheckStatus.networkUnreachable;
    }
    return PortCheckStatus.unknownFailure;
  }

  static String _describeSocketException(String target, String message) {
    final normalized = message.trim();
    return normalized.isEmpty
        ? '$target unavailable.'
        : '$target unavailable: $normalized';
  }
}

class _PortTarget {
  final String host;
  final int port;
  final String description;

  const _PortTarget({
    required this.host,
    required this.port,
    required this.description,
  });
}
