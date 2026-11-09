import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:boomprint/connection_preflight.dart';
import 'package:boomprint/printer_url_formats.dart';
import 'package:boomprint/settings_manager.dart';

enum DiagnosticEndpointKind { stream, ftps, mqtt }

class ConnectionDiagnosticsReport {
  final DateTime capturedAt;
  final String streamUrl;
  final DesktopSessionDiagnostic desktopSession;
  final GraphicsDiagnostic graphics;
  final List<EndpointDiagnostic> endpoints;

  const ConnectionDiagnosticsReport({
    required this.capturedAt,
    required this.streamUrl,
    required this.desktopSession,
    required this.graphics,
    required this.endpoints,
  });

  Map<String, dynamic> toJson({bool includePem = true}) => {
    'capturedAt': capturedAt.toIso8601String(),
    'streamUrl': streamUrl,
    'desktopSession': desktopSession.toJson(),
    'graphics': graphics.toJson(),
    'endpoints': endpoints
        .map((endpoint) => endpoint.toJson(includePem: includePem))
        .toList(growable: false),
  };

  String toPrettyJson({bool includePem = true}) => const JsonEncoder.withIndent(
    '  ',
  ).convert(toJson(includePem: includePem));

  String toSummaryText() {
    final buffer = StringBuffer()
      ..writeln('Captured: ${capturedAt.toIso8601String()}')
      ..writeln('Stream URL: $streamUrl')
      ..writeln(
        'Desktop session: ${desktopSession.displayLabel}${desktopSession.details.isNotEmpty ? ' (${desktopSession.details})' : ''}',
      )
      ..writeln(
        'Graphics: ${graphics.availabilityLabel}${graphics.details.isNotEmpty ? ' (${graphics.details})' : ''}',
      )
      ..writeln();
    for (final endpoint in endpoints) {
      buffer
        ..writeln(endpoint.label)
        ..writeln('  Host: ${endpoint.host}:${endpoint.port}')
        ..writeln(
          '  TCP: ${endpoint.tcp.status.name} - ${endpoint.tcp.message}',
        )
        ..writeln(
          '  TLS: ${endpoint.tls == null
              ? 'not attempted'
              : endpoint.tls!.trusted
              ? 'trusted'
              : 'untrusted'}',
        );
      final cert = endpoint.tls?.certificate;
      if (cert != null) {
        buffer
          ..writeln('  Subject: ${cert.subject}')
          ..writeln('  Issuer: ${cert.issuer}')
          ..writeln(
            '  Validity: ${cert.startValidity.toIso8601String()} -> ${cert.endValidity.toIso8601String()}',
          )
          ..writeln('  SHA-1: ${cert.sha1Fingerprint}');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  Uint8List toZipBytes({bool includePem = true}) {
    final archive = Archive();
    archive.addFile(
      ArchiveFile.string('report.json', toPrettyJson(includePem: includePem)),
    );
    archive.addFile(ArchiveFile.string('summary.txt', toSummaryText()));
    archive.addFile(
      ArchiveFile.string(
        'manifest.json',
        const JsonEncoder.withIndent('  ').convert({
          'capturedAt': capturedAt.toIso8601String(),
          'desktopSession': desktopSession.toJson(),
          'graphics': graphics.toJson(),
          'fileCount': _zipFileCount(includePem: includePem),
          'files': _zipFileNames(includePem: includePem),
        }),
      ),
    );

    for (final endpoint in endpoints) {
      final key = _slugify(endpoint.label);
      archive.addFile(
        ArchiveFile.string(
          'endpoints/$key.json',
          const JsonEncoder.withIndent(
            '  ',
          ).convert(endpoint.toJson(includePem: includePem)),
        ),
      );
      final cert = endpoint.tls?.certificate;
      if (includePem && cert != null) {
        archive.addFile(ArchiveFile.string('certs/$key.pem', cert.pem));
      }
    }

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  List<String> _zipFileNames({required bool includePem}) {
    final names = <String>['report.json', 'summary.txt', 'manifest.json'];
    for (final endpoint in endpoints) {
      final key = _slugify(endpoint.label);
      names.add('endpoints/$key.json');
      if (includePem && endpoint.tls?.certificate != null) {
        names.add('certs/$key.pem');
      }
    }
    return names;
  }

  int _zipFileCount({required bool includePem}) =>
      _zipFileNames(includePem: includePem).length;
}

class EndpointDiagnostic {
  final String label;
  final DiagnosticEndpointKind kind;
  final String host;
  final int port;
  final bool tlsExpected;
  final PortCheckResult tcp;
  final TlsDiagnostic? tls;

  const EndpointDiagnostic({
    required this.label,
    required this.kind,
    required this.host,
    required this.port,
    required this.tlsExpected,
    required this.tcp,
    required this.tls,
  });

  bool get hasCertificate => tls?.certificate != null;

  Map<String, dynamic> toJson({bool includePem = true}) => {
    'label': label,
    'kind': kind.name,
    'host': host,
    'port': port,
    'tlsExpected': tlsExpected,
    'tcp': {
      'status': tcp.status.name,
      'message': tcp.message,
      'elapsedMs': tcp.elapsed.inMilliseconds,
    },
    if (tls != null) 'tls': tls!.toJson(includePem: includePem),
  };
}

class DesktopSessionDiagnostic {
  final String sessionType;
  final String displayServer;
  final String details;

  const DesktopSessionDiagnostic({
    required this.sessionType,
    required this.displayServer,
    required this.details,
  });

  String get displayLabel {
    final normalized = displayServer.trim().toLowerCase();
    if (normalized == 'wayland') return 'Wayland';
    if (normalized == 'x11') return 'X11';
    if (normalized.isEmpty) return 'Unknown';
    return displayServer;
  }

  Map<String, dynamic> toJson() => {
    'sessionType': sessionType,
    'displayServer': displayServer,
    'details': details,
  };
}

class GraphicsDiagnostic {
  final bool hardwareAccelerationAvailable;
  final bool softwareForced;
  final String backendHint;
  final String details;

  const GraphicsDiagnostic({
    required this.hardwareAccelerationAvailable,
    required this.softwareForced,
    required this.backendHint,
    required this.details,
  });

  String get availabilityLabel {
    if (softwareForced) return 'Software rendering forced';
    return hardwareAccelerationAvailable
        ? 'Hardware likely available'
        : 'Hardware unavailable';
  }

  Map<String, dynamic> toJson() => {
    'hardwareAccelerationAvailable': hardwareAccelerationAvailable,
    'softwareForced': softwareForced,
    'backendHint': backendHint,
    'details': details,
  };
}

class TlsDiagnostic {
  final bool attempted;
  final bool trusted;
  final String message;
  final Duration elapsed;
  final CertificateDiagnostic? certificate;

  const TlsDiagnostic({
    required this.attempted,
    required this.trusted,
    required this.message,
    required this.elapsed,
    required this.certificate,
  });

  Map<String, dynamic> toJson({bool includePem = true}) => {
    'attempted': attempted,
    'trusted': trusted,
    'message': message,
    'elapsedMs': elapsed.inMilliseconds,
    if (certificate != null)
      'certificate': certificate!.toJson(includePem: includePem),
  };
}

class CertificateDiagnostic {
  final String subject;
  final String issuer;
  final DateTime startValidity;
  final DateTime endValidity;
  final String sha1Fingerprint;
  final String pem;

  const CertificateDiagnostic({
    required this.subject,
    required this.issuer,
    required this.startValidity,
    required this.endValidity,
    required this.sha1Fingerprint,
    required this.pem,
  });

  Map<String, dynamic> toJson({bool includePem = true}) => {
    'subject': subject,
    'issuer': issuer,
    'startValidity': startValidity.toIso8601String(),
    'endValidity': endValidity.toIso8601String(),
    'sha1Fingerprint': sha1Fingerprint,
    if (includePem) 'pem': pem,
  };
}

class ConnectionDiagnostics {
  static Future<ConnectionDiagnosticsReport> run({
    required AppSettings settings,
    String? streamUrl,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final resolvedStreamUrl =
        (streamUrl ?? ConnectionPreflight.buildStreamUrl(settings)).trim();
    final desktopSession = _desktopSessionDiagnostic();
    final graphics = _graphicsDiagnostic(desktopSession);
    final targets = _buildTargets(settings, resolvedStreamUrl);
    final endpoints = await Future.wait(
      targets.map((target) => _probeTarget(target, timeout: timeout)),
    );
    return ConnectionDiagnosticsReport(
      capturedAt: DateTime.now(),
      streamUrl: resolvedStreamUrl,
      desktopSession: desktopSession,
      graphics: graphics,
      endpoints: endpoints,
    );
  }

  static DesktopSessionDiagnostic _desktopSessionDiagnostic() {
    final xdgSessionType =
        Platform.environment['XDG_SESSION_TYPE']?.trim() ?? '';
    final waylandDisplay =
        Platform.environment['WAYLAND_DISPLAY']?.trim() ?? '';
    final display = Platform.environment['DISPLAY']?.trim() ?? '';

    final displayServer = switch (xdgSessionType.toLowerCase()) {
      'wayland' => 'Wayland',
      'x11' => 'X11',
      _ =>
        waylandDisplay.isNotEmpty
            ? 'Wayland'
            : display.isNotEmpty
            ? 'X11'
            : 'Unknown',
    };

    final details = <String>[
      if (xdgSessionType.isNotEmpty) 'XDG_SESSION_TYPE=$xdgSessionType',
      if (waylandDisplay.isNotEmpty) 'WAYLAND_DISPLAY=$waylandDisplay',
      if (display.isNotEmpty) 'DISPLAY=$display',
    ].join(', ');

    return DesktopSessionDiagnostic(
      sessionType: xdgSessionType,
      displayServer: displayServer,
      details: details,
    );
  }

  static GraphicsDiagnostic _graphicsDiagnostic(
    DesktopSessionDiagnostic session,
  ) {
    final env = Platform.environment;
    final softwareFlags = <String>[
      if ((env['LIBGL_ALWAYS_SOFTWARE'] ?? '').trim() == '1')
        'LIBGL_ALWAYS_SOFTWARE=1',
      if ((env['GALLIUM_DRIVER'] ?? '').trim().toLowerCase() == 'llvmpipe')
        'GALLIUM_DRIVER=llvmpipe',
      if ((env['MESA_LOADER_DRIVER_OVERRIDE'] ?? '').trim().toLowerCase() ==
          'llvmpipe')
        'MESA_LOADER_DRIVER_OVERRIDE=llvmpipe',
    ];
    final renderNodes = [
      '/dev/dri/renderD128',
      '/dev/dri/renderD129',
      '/dev/dri/card0',
    ];
    final renderDeviceAvailable = renderNodes.any((path) {
      try {
        return File(path).existsSync();
      } catch (_) {
        return false;
      }
    });
    final softwareForced = softwareFlags.isNotEmpty;
    final hardwareAccelerationAvailable =
        !softwareForced && renderDeviceAvailable;
    final backendHint = session.displayLabel;
    final details = <String>[
      if (softwareFlags.isNotEmpty) softwareFlags.join(', '),
      if (renderDeviceAvailable) 'DRI device present',
      if (!renderDeviceAvailable) 'No DRI render node detected',
      'backend=$backendHint',
    ].join(', ');

    return GraphicsDiagnostic(
      hardwareAccelerationAvailable: hardwareAccelerationAvailable,
      softwareForced: softwareForced,
      backendHint: backendHint,
      details: details,
    );
  }

  static List<_DiagnosticTarget> _buildTargets(
    AppSettings settings,
    String streamUrl,
  ) {
    final targets = <_DiagnosticTarget>[];
    final streamUri = Uri.tryParse(streamUrl);
    final streamHost = streamUri?.host.trim().isNotEmpty == true
        ? streamUri!.host
        : settings.printerIp.trim();
    final streamScheme = (streamUri?.scheme ?? '').toLowerCase();
    final streamPort = streamUri?.hasPort == true
        ? streamUri!.port
        : switch (streamScheme) {
            'rtsp' => 554,
            'rtsps' => 322,
            _ => _defaultStreamPort(settings),
          };

    if (streamHost.isNotEmpty && streamPort > 0) {
      targets.add(
        _DiagnosticTarget(
          label: streamScheme == 'rtsps' ? 'RTSPS stream' : 'RTSP stream',
          kind: DiagnosticEndpointKind.stream,
          host: streamHost,
          port: streamPort,
          tlsExpected: streamScheme == 'rtsps',
        ),
      );
    }

    final controlHost = settings.printerIp.trim().isNotEmpty
        ? settings.printerIp.trim()
        : streamHost;
    if (controlHost.isNotEmpty) {
      targets.add(
        _DiagnosticTarget(
          label: 'FTPS file service',
          kind: DiagnosticEndpointKind.ftps,
          host: controlHost,
          port: 990,
          tlsExpected: true,
        ),
      );
      targets.add(
        _DiagnosticTarget(
          label: 'MQTT control',
          kind: DiagnosticEndpointKind.mqtt,
          host: controlHost,
          port: 8883,
          tlsExpected: true,
        ),
      );
    }

    return targets;
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

  static Future<EndpointDiagnostic> _probeTarget(
    _DiagnosticTarget target, {
    required Duration timeout,
  }) async {
    final tcp = await _checkTcp(target, timeout: timeout);
    final tls = target.tlsExpected
        ? await _checkTls(target, timeout: timeout)
        : null;
    return EndpointDiagnostic(
      label: target.label,
      kind: target.kind,
      host: target.host,
      port: target.port,
      tlsExpected: target.tlsExpected,
      tcp: tcp,
      tls: tls,
    );
  }

  static Future<PortCheckResult> _checkTcp(
    _DiagnosticTarget target, {
    required Duration timeout,
  }) async {
    final started = DateTime.now();
    try {
      final socket = await Socket.connect(
        target.host,
        target.port,
      ).timeout(timeout);
      socket.destroy();
      return PortCheckResult(
        label: target.label,
        host: target.host,
        port: target.port,
        required: target.kind != DiagnosticEndpointKind.ftps,
        status: PortCheckStatus.reachable,
        message: '${target.label} TCP port is reachable.',
        elapsed: DateTime.now().difference(started),
      );
    } on TimeoutException {
      return PortCheckResult(
        label: target.label,
        host: target.host,
        port: target.port,
        required: target.kind != DiagnosticEndpointKind.ftps,
        status: PortCheckStatus.timedOut,
        message: '${target.label} timed out after ${timeout.inSeconds}s.',
        elapsed: DateTime.now().difference(started),
      );
    } on SocketException catch (e) {
      return PortCheckResult(
        label: target.label,
        host: target.host,
        port: target.port,
        required: target.kind != DiagnosticEndpointKind.ftps,
        status: _classifySocketException(e.message),
        message: '${target.label} unavailable: ${e.message}',
        elapsed: DateTime.now().difference(started),
      );
    } catch (e) {
      return PortCheckResult(
        label: target.label,
        host: target.host,
        port: target.port,
        required: target.kind != DiagnosticEndpointKind.ftps,
        status: PortCheckStatus.unknownFailure,
        message: '${target.label} check failed: $e',
        elapsed: DateTime.now().difference(started),
      );
    }
  }

  static Future<TlsDiagnostic> _checkTls(
    _DiagnosticTarget target, {
    required Duration timeout,
  }) async {
    final strictStarted = DateTime.now();
    try {
      final socket = await SecureSocket.connect(
        target.host,
        target.port,
      ).timeout(timeout);
      final cert = socket.peerCertificate;
      socket.destroy();
      return TlsDiagnostic(
        attempted: true,
        trusted: true,
        message: 'TLS handshake succeeded with system trust.',
        elapsed: DateTime.now().difference(strictStarted),
        certificate: cert == null ? null : _certificateDiagnostic(cert),
      );
    } catch (strictError) {
      final permissiveStarted = DateTime.now();
      X509Certificate? captured;
      try {
        final socket = await SecureSocket.connect(
          target.host,
          target.port,
          onBadCertificate: (certificate) {
            captured = certificate;
            return true;
          },
        ).timeout(timeout);
        captured ??= socket.peerCertificate;
        socket.destroy();
        return TlsDiagnostic(
          attempted: true,
          trusted: false,
          message:
              'TLS certificate is not trusted by the system, but the endpoint presented a certificate.',
          elapsed: DateTime.now().difference(permissiveStarted),
          certificate: captured == null
              ? null
              : _certificateDiagnostic(captured!),
        );
      } catch (permissiveError) {
        return TlsDiagnostic(
          attempted: true,
          trusted: false,
          message:
              'TLS handshake failed. Strict error: $strictError. Permissive error: $permissiveError',
          elapsed: DateTime.now().difference(strictStarted),
          certificate: captured == null
              ? null
              : _certificateDiagnostic(captured!),
        );
      }
    }
  }

  static CertificateDiagnostic _certificateDiagnostic(X509Certificate cert) {
    return CertificateDiagnostic(
      subject: cert.subject,
      issuer: cert.issuer,
      startValidity: cert.startValidity,
      endValidity: cert.endValidity,
      sha1Fingerprint: _hex(cert.sha1),
      pem: cert.pem,
    );
  }

  static String _hex(Uint8List bytes) {
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
  }

  static PortCheckStatus _classifySocketException(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('refused')) {
      return PortCheckStatus.connectionRefused;
    }
    if (normalized.contains('timed out') || normalized.contains('timeout')) {
      return PortCheckStatus.timedOut;
    }
    if (normalized.contains('unreachable') ||
        normalized.contains('network is unreachable') ||
        normalized.contains('host is unreachable')) {
      return PortCheckStatus.networkUnreachable;
    }
    return PortCheckStatus.unknownFailure;
  }
}

class _DiagnosticTarget {
  final String label;
  final DiagnosticEndpointKind kind;
  final String host;
  final int port;
  final bool tlsExpected;

  const _DiagnosticTarget({
    required this.label,
    required this.kind,
    required this.host,
    required this.port,
    required this.tlsExpected,
  });
}

String _slugify(String value) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final trimmed = normalized.replaceAll(RegExp(r'^_+|_+$'), '');
  return trimmed.isEmpty ? 'endpoint' : trimmed;
}
