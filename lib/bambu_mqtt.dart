import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/printer_firmware.dart';

// ==========
// MQTT Client
// ==========

enum BambuLogLevel { debug, info, warning, error }

class BambuLogEvent {
  final DateTime timestamp;
  final BambuLogLevel level;
  final String message;

  const BambuLogEvent({
    required this.timestamp,
    required this.level,
    required this.message,
  });
}

class BambuMqtt {
  final BambuLanConfig config;
  late final MqttServerClient _client =
      MqttServerClient(config.printerIp, _clientId())
        ..port = config.mqttPort
        ..secure = true
        ..keepAlivePeriod = 30
        ..logging(on: false);

  final _reports = StreamController<BambuReportEvent>.broadcast();
  final _commands = StreamController<BambuCommandEvent>.broadcast();
  final _logs = StreamController<BambuLogEvent>.broadcast();
  int _seq = 1;
  String? _activeSerial;

  Stream<BambuReportEvent> get reportStream => _reports.stream;
  Stream<BambuCommandEvent> get commandStream => _commands.stream;
  Stream<BambuLogEvent> get logStream => _logs.stream;
  bool get isConnected =>
      _client.connectionStatus?.state == MqttConnectionState.connected;

  BambuMqtt(this.config);

  void _log(BambuLogLevel level, String message) {
    final event = BambuLogEvent(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    );
    if (!_logs.isClosed) {
      _logs.add(event);
    }
    if (level == BambuLogLevel.error) {
      stderr.writeln(message);
    }
  }

  Future<void> connect() async {
    _log(
      BambuLogLevel.info,
      'MQTT connect start host=${config.printerIp} port=${config.mqttPort} '
      'serial=${config.serial ?? '(unset)'}',
    );
    // TLS context
    if (config.caCertPem != null && config.caCertPem!.trim().isNotEmpty) {
      const withTrustedRoots = false;
      final ctx = SecurityContext(withTrustedRoots: withTrustedRoots);
      final bytes = Uint8List.fromList(utf8.encode(config.caCertPem!));
      try {
        ctx.setTrustedCertificatesBytes(bytes);
        _client.securityContext = ctx;
        _log(BambuLogLevel.info, 'MQTT applied custom CA certificate.');
      } catch (e) {
        _log(BambuLogLevel.warning, 'Failed to apply custom CA cert: $e');
      }
    }

    if (config.allowBadCerts) {
      // _client.onBadCertificate = (X509Certificate c) {
      //   return true; // accept any certificate
      // };

      _client.onBadCertificate = (Object c) {
        return true; // accept any certificate
      };
      _log(BambuLogLevel.warning, 'MQTT accepting bad certificates.');
    }

    //_client.setProtocolV311();
    _client.resubscribeOnAutoReconnect = true;
    _client.autoReconnect = true;

    _client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(_clientId())
        .authenticateAs('bblp', config.accessCode)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    _client.onDisconnected = () {
      _log(
        BambuLogLevel.warning,
        'MQTT disconnected: ${_client.connectionStatus?.disconnectionOrigin}',
      );
    };

    try {
      await _client.connect();
      _log(BambuLogLevel.info, 'MQTT connected.');
    } on Exception {
      _client.disconnect();
      _log(BambuLogLevel.error, 'MQTT connection failed.');
      rethrow;
    }

    // Subscribe to reports (always wildcard; specific serial may differ by case)
    _activeSerial = _normalizeSerial(config.serial);
    _client.subscribe('device/+/report', MqttQos.atMostOnce);
    if (_activeSerial != null) {
      _client.subscribe('device/${_activeSerial!}/report', MqttQos.atMostOnce);
    }
    _log(
      BambuLogLevel.info,
      'MQTT subscribed to device/+/report'
      '${_activeSerial != null ? ' and device/${_activeSerial!}/report' : ''}.',
    );

    _client.updates?.listen((events) {
      for (final evt in events) {
        final rec = evt.payload as MqttPublishMessage;
        final msg = MqttPublishPayload.bytesToStringAsString(
          rec.payload.message,
        );
        try {
          final jsonMap = json.decode(msg) as Map<String, dynamic>;
          final type = _detectType(jsonMap);
          final ps = parsePrintStatus(jsonMap);
          final firmwareVersion = extractFirmwareVersion(jsonMap);
          final e = BambuReportEvent(
            topic: evt.topic,
            json: jsonMap,
            type: type,
            firmwareVersion: firmwareVersion,
            printStatus: ps,
          );
          _log(
            BambuLogLevel.debug,
            'MQTT report ${evt.topic} type=${type ?? '(unknown)'} '
            'state=${ps?.gcodeState ?? '(n/a)'}',
          );
          // Try to learn serial from the first report if not set
          _maybeInferSerial(evt.topic, jsonMap);

          _reports.add(e);
        } catch (e) {
          final maxLen = msg.length < 200 ? msg.length : 200;
          _log(
            BambuLogLevel.error,
            'MQTT report parse failed: $e | topic=${evt.topic} | '
            'msg=${msg.substring(0, maxLen)}',
          );
        }
      }
    });
  }

  String _clientId() => 'bambu_dart_${DateTime.now().millisecondsSinceEpoch}';

  String? _normalizeSerial(String? serial) {
    final trimmed = serial?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  String? _detectType(Map<String, dynamic> j) {
    // Heuristic; schema can vary by firmware
    final p = j['print'];
    if (p is Map<String, dynamic>) {
      // Prefer explicit gcode_state if present (e.g., RUNNING, FINISH, IDLE)
      final gs = p['gcode_state'];
      if (gs is String && gs.isNotEmpty) return gs;
      // Fallback to mc_print_stage numeric mapping
      final stage = p['mc_print_stage'];
      if (stage is String || stage is num) {
        final s = stage.toString();
        switch (s) {
          case '0':
            return 'IDLE';
          case '1':
            return 'PREPARE';
          case '2':
            return 'RUNNING';
          case '3':
            return 'PAUSED';
          case '4':
            return 'FINISH';
          default:
            return 'PRINT';
        }
      }
      return 'PRINT';
    }
    if (j.containsKey('system')) {
      return 'SYSTEM';
    }
    return null;
  }

  /// Parses the printer's `print` report without requiring a live connection.
  ///
  /// Public for focused protocol tests; normal callers receive this through
  /// [reportStream].
  BambuPrintStatus? parsePrintStatus(Map<String, dynamic> j) {
    final p = j['print'];
    if (p is! Map) return null;
    T? pick<T>(String k) {
      final v = p[k];
      if (v == null) return null;
      if (T == int) {
        if (v is int) return v as T;
        if (v is String) return int.tryParse(v) as T?;
        if (v is num) return v.toInt() as T;
      }
      if (T == double) {
        if (v is double) return v as T;
        if (v is int) return v.toDouble() as T;
        if (v is String) return double.tryParse(v) as T?;
      }
      if (T == String) {
        if (v is String) return v as T;
        return v.toString() as T;
      }
      return v as T?;
    }

    // A command acknowledgement may have a `print` envelope but no state.
    // Leave it empty so the controller can retain the last observed state.
    final gcodeState = pick<String>('gcode_state') ?? '';
    final hmsPresent = p.containsKey('hms');
    final filamentPresent = p.containsKey('ams') || p.containsKey('vt_tray');
    final ams = _asStringDynamicMap(p['ams']);
    final printError = pick<int>('print_error');
    return BambuPrintStatus(
      gcodeState: gcodeState,
      percent: pick<int>('mc_percent'),
      remainingMinutes: pick<int>('mc_remaining_time'),
      gcodeFile: pick<String>('gcode_file'),
      layer: pick<int>('layer_num'),
      totalLayers: pick<int>('total_layer_num'),
      bedTemp: pick<double>('bed_temper'),
      bedTarget: pick<double>('bed_target_temper'),
      nozzleTemp: pick<double>('nozzle_temper'),
      nozzleTarget: pick<double>('nozzle_target_temper'),
      chamberTemp: pick<double>('chamber_temper'),
      nozzleType: pick<String>('nozzle_type'),
      nozzleDiameter: pick<String>('nozzle_diameter'),
      speedLevel: pick<int>('spd_lvl'),
      speedMag: pick<int>('spd_mag'),
      subtaskName: pick<String>('subtask_name'),
      taskId: pick<String>('task_id'),
      jobId: pick<String>('job_id'),
      wifiSignal: pick<String>('wifi_signal'),
      stage: pick<int>('stg_cur') ?? pick<int>('mc_print_stage'),
      printError: printError,
      printerMessage: _printerFailureMessage(p, printError),
      hms: _parseHmsEvents(p['hms']),
      hasHmsReport: hmsPresent,
      filamentTrays: _parseFilamentTrays(p),
      hasFilamentReport: filamentPresent,
      activeTrayIndex: _asInt(ams?['tray_now'] ?? p['tray_now']),
      targetTrayIndex: _asInt(ams?['tray_tar'] ?? p['tray_tar']),
    );
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  int? _asRemainingPercent(Object? value) {
    final parsed = switch (value) {
      num() => value.toDouble(),
      String() => double.tryParse(value.trim()),
      _ => null,
    };
    // Printers use negative and out-of-range values to mean unavailable.
    // Do not surface those sentinels as a plausible remaining percentage.
    if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 100) {
      return null;
    }
    return parsed.round();
  }

  String? _firstNonEmptyString(Iterable<Object?> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != '0') return text;
    }
    return null;
  }

  String? _printerFailureMessage(Map print, int? printError) {
    final result = print['result']?.toString().trim().toLowerCase() ?? '';
    final errorCode = _asInt(print['error_code']);
    final hasFailure =
        printError != null && printError != 0 ||
        errorCode != null && errorCode != 0 ||
        const {
          'fail',
          'failed',
          'error',
          'reject',
          'rejected',
          'failure',
        }.contains(result);
    if (!hasFailure) return null;
    return _firstNonEmptyString([print['reason'], print['message']]);
  }

  List<BambuHmsEvent> _parseHmsEvents(Object? value) {
    if (value is! List) return const [];
    final events = <BambuHmsEvent>[];
    for (final item in value) {
      final event = _asStringDynamicMap(item);
      if (event == null) continue;
      final code = _asInt(event['code']);
      final attr = _asInt(event['attr']);
      if (code == null || attr == null) continue;
      events.add(
        BambuHmsEvent(
          code: code,
          attr: attr,
          message: _firstNonEmptyString([
            event['message'],
            event['description'],
            event['msg'],
          ]),
        ),
      );
    }
    return events;
  }

  List<BambuFilamentTray> _parseFilamentTrays(Map print) {
    final trays = <BambuFilamentTray>[];
    final ams = _asStringDynamicMap(print['ams']);
    final amsUnits = ams?['ams'];
    if (amsUnits is List) {
      for (var amsIndex = 0; amsIndex < amsUnits.length; amsIndex++) {
        final unit = _asStringDynamicMap(amsUnits[amsIndex]);
        final slots = unit?['tray'];
        if (slots is! List) continue;
        for (var position = 0; position < slots.length; position++) {
          final slot = _asStringDynamicMap(slots[position]);
          if (slot == null) continue;
          final slotIndex = _asInt(slot['id']) ?? position;
          final type = _firstNonEmptyString([slot['tray_type']]);
          final name = _firstNonEmptyString([slot['tray_id_name']]);
          final color = _firstNonEmptyString([slot['tray_color']]);
          final remaining = _asRemainingPercent(slot['remain']);
          final hasDetails =
              type != null ||
              name != null ||
              color != null ||
              remaining != null ||
              slot.length > 1;
          if (!hasDetails) continue;
          trays.add(
            BambuFilamentTray(
              trayIndex: amsIndex * 4 + slotIndex,
              amsIndex: amsIndex,
              slotIndex: slotIndex,
              type: type,
              name: name,
              color: color,
              remainingPercent: remaining,
            ),
          );
        }
      }
    }

    final external = _asStringDynamicMap(print['vt_tray']);
    if (external != null) {
      final type = _firstNonEmptyString([external['tray_type']]);
      final name = _firstNonEmptyString([external['tray_id_name']]);
      final color = _firstNonEmptyString([external['tray_color']]);
      final remaining = _asRemainingPercent(external['remain']);
      if (type != null || name != null || color != null || remaining != null) {
        trays.add(
          BambuFilamentTray(
            trayIndex: 254,
            isExternal: true,
            type: type,
            name: name,
            color: color,
            remainingPercent: remaining,
          ),
        );
      }
    }
    return trays;
  }

  void _maybeInferSerial(String topic, Map<String, dynamic> j) {
    final m = RegExp(r'^device/([^/]+)/report').firstMatch(topic);
    if (m != null) {
      final topicSerial = _normalizeSerial(m.group(1));
      if (topicSerial != null &&
          topicSerial.isNotEmpty &&
          topicSerial != _activeSerial) {
        stderr.writeln(
          'MQTT serial inferred from report topic: '
          '${_activeSerial ?? '(unset)'} -> $topicSerial',
        );
        _activeSerial = topicSerial;
      }
      return;
    }

    if (_activeSerial != null) {
      return;
    }

    // Try payload fields often containing serial/dev id (best-effort).
    for (final key in ['sn', 'serial', 'dev_id', 'usn']) {
      final v = j[key];
      if (v is String && v.isNotEmpty) {
        _activeSerial = _normalizeSerial(v);
        break;
      }
    }
  }

  Future<void> dispose() async {
    _log(BambuLogLevel.info, 'MQTT dispose requested.');
    await _reports.close();
    await _commands.close();
    await _logs.close();
    _client.disconnect();
  }

  /// Publish a raw JSON payload to the printer's request topic.
  Future<void> publishRequest(
    Map<String, dynamic> payload, {
    MqttQos qos = MqttQos.atMostOnce,
  }) async {
    final sn =
        _normalizeSerial(_activeSerial) ?? _normalizeSerial(config.serial);
    if (sn == null) {
      throw StateError(
        'Printer serial is unknown; provide BambuLanConfig.serial or wait for first report.',
      );
    }
    final topic = 'device/$sn/request';
    final b = MqttClientPayloadBuilder();
    b.addUTF8String(jsonEncode(payload));
    // Log the outbound command explicitly
    _log(BambuLogLevel.info, 'MQTT publish $topic ${jsonEncode(payload)}');
    final evt = BambuCommandEvent(
      topic: topic,
      payload: payload,
      qos: qos,
      timestamp: DateTime.now(),
    );
    _commands.add(evt);
    _client.publishMessage(topic, qos, b.payload!);
  }

  // ===== Convenience Commands (best-effort; firmware may vary) =====

  Future<void> sendGcode(String line) async {
    final payload = {
      'system': {
        'sequence_id': (_seq++).toString(),
        'command': 'gcode_line',
        'param': line,
      },
    };
    await publishRequest(payload);
  }

  Future<void> home({bool x = true, bool y = true, bool z = true}) async {
    final axes = [if (x) 'X', if (y) 'Y', if (z) 'Z'].join(' ');
    await sendGcode('G28 $axes');
  }

  Future<void> moveRelative({
    double? x,
    double? y,
    double? z,
    int feed = 6000,
  }) async {
    // Relative move: set to relative, move, then back to absolute
    final parts = <String>[];
    if (x != null) parts.add('X${x.toStringAsFixed(2)}');
    if (y != null) parts.add('Y${y.toStringAsFixed(2)}');
    if (z != null) parts.add('Z${z.toStringAsFixed(2)}');
    final cmd = 'G91\nG1 ${parts.join(' ')} F$feed\nG90';
    await sendGcode(cmd);
  }

  Future<void> pausePrint() async {
    final payload = {
      'print': {'sequence_id': (_seq++).toString(), 'command': 'pause'},
    };
    await publishRequest(payload);
  }

  Future<void> resumePrint() async {
    final payload = {
      'print': {'sequence_id': (_seq++).toString(), 'command': 'resume'},
    };
    await publishRequest(payload);
  }

  Future<void> cancelPrint() async {
    await _sendPrintCommand(command: 'stop', fallbackCommand: 'cancel');
  }

  /// Set print speed factor using standard G-code (`M220 S<percent>`).
  /// Common range: 10..300 (%). Values are clamped conservatively.
  Future<void> setSpeedPercent(int percent) async {
    final p = percent.clamp(10, 300);
    await sendGcode('M220 S$p');
  }

  /// Optional: Set flow rate factor via G-code (`M221 S<percent>`).
  Future<void> setFlowPercent(int percent) async {
    final p = percent.clamp(10, 300);
    await sendGcode('M221 S$p');
  }

  /// Attempt to set a predefined speed profile. If a native profile command
  /// is unsupported on the target firmware, fall back to M220 percentage.
  Future<void> setSpeedProfile(BambuSpeedProfile profile) async {
    final seq = (_seq++).toString();
    final payload = {
      'print': {
        'sequence_id': seq,
        'command': 'print_speed',
        'param': profile.mqttParam,
      },
    };
    try {
      _log(
        BambuLogLevel.info,
        'MQTT speed profile request: profile=${profile.label} '
        'seq=$seq param=${profile.mqttParam}',
      );
      final ackFuture = _waitForAck(sequenceId: seq, command: 'print_speed');
      await publishRequest(payload);
      final ack = await ackFuture;
      _log(
        BambuLogLevel.info,
        'MQTT speed profile ACK: envelope=${ack.envelope} '
        'seq=${ack.sequenceId} result=${ack.payload['result'] ?? ''} '
        'reason=${ack.payload['reason'] ?? ''} '
        'error_code=${ack.payload['error_code'] ?? ''}',
      );
      if (_ackIndicatesFailure(ack.payload)) {
        throw StateError(_ackFailureMessage(ack.payload));
      }
    } catch (e) {
      _log(
        BambuLogLevel.warning,
        'MQTT speed profile fallback: profile=${profile.label} '
        'reason=$e fallback_percent=${profile.fallbackPercent}',
      );
      await setSpeedPercent(profile.fallbackPercent);
    }
  }

  /// Convenience: LED control example (chamber light on/off)
  Future<void> setChamberLight(bool on, {String ledNode = 'chamber_light'}) {
    final payload = {
      'system': {
        'sequence_id': (_seq++).toString(),
        'command': 'ledctrl',
        'led_node': ledNode,
        'led_mode': on ? 'on' : 'off',
        'led_on_time': 500,
        'led_off_time': 500,
        'loop_times': 1,
        'interval_time': 1000,
      },
    };
    return publishRequest(payload);
  }

  String _fileNameFromPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return trimmed;
    final parts = trimmed.split('/');
    return parts.isEmpty ? trimmed : parts.last;
  }

  String _normalizePrinterPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '/';
    if (trimmed.startsWith('/')) return trimmed;
    return '/$trimmed';
  }

  String _toSdcardPath(String path) {
    final p = _normalizePrinterPath(path);
    if (p.startsWith('/sdcard/')) return p;
    if (p == '/sdcard') return '/sdcard';
    if (p.startsWith('/mnt/sdcard/')) {
      return '/sdcard/${p.substring('/mnt/sdcard/'.length)}';
    }
    if (p == '/mnt/sdcard') return '/sdcard';
    if (p == '/') return '/sdcard';
    return '/sdcard$p';
  }

  String _projectUrlFromPath(String path) {
    return 'file://${_toSdcardPath(path)}';
  }

  /// Print a 3MF project file already on printer SD using `project_file`.
  Future<String> printProjectFile({
    required String projectPath,
    int plateIndex = 1,
    List<int>? amsMapping,
    bool useAms = true,
    bool timelapse = true,
    bool bedLevelling = true,
    bool flowCalibration = true,
    bool vibrationCalibration = true,
    bool layerInspection = true,
  }) async {
    final seq = (_seq++).toString();
    final printerPath = _toSdcardPath(projectPath);
    final projectUrl = _projectUrlFromPath(projectPath);
    final fileName = _fileNameFromPath(printerPath);
    final subtaskName = fileName.replaceFirst(
      RegExp(r'(\.gcode)?\.3mf$', caseSensitive: false),
      '',
    );
    final payload = {
      'print': {
        'sequence_id': seq,
        'command': 'project_file',
        'param': 'Metadata/plate_$plateIndex.gcode',
        'project_id': '0',
        'profile_id': '0',
        'task_id': '0',
        'subtask_id': '0',
        'subtask_name': subtaskName,
        'file': '',
        'url': projectUrl,
        'md5': '',
        'timelapse': timelapse,
        'bed_type': 'auto',
        'bed_levelling': bedLevelling,
        'flow_cali': flowCalibration,
        'vibration_cali': vibrationCalibration,
        'layer_inspect': layerInspection,
        'ams_mapping': amsMapping ?? <int>[],
        'use_ams': useAms,
      },
    };
    await publishRequest(payload);
    return seq;
  }

  /// Print a G-code file already on the printer.
  Future<String> printGcodeFile(String gcodePath) async {
    final seq = (_seq++).toString();
    final printerPath = _toSdcardPath(gcodePath);
    final payload = {
      'print': {
        'sequence_id': seq,
        'command': 'gcode_file',
        'param': printerPath,
      },
    };
    await publishRequest(payload, qos: MqttQos.atMostOnce);
    return seq;
  }

  /// Request a full status push (use sparingly on some models).
  Future<void> requestPushAll() async {
    final payload = {
      'pushing': {
        'sequence_id': (_seq++).toString(),
        'command': 'pushall',
        'version': 1,
        'push_target': 1,
      },
      // Required by some firmware revisions before they send lights_report
      // and other full-status fields.
      'user_id': '1234567890',
    };
    await publishRequest(payload, qos: MqttQos.atMostOnce);
  }

  Future<void> _sendPrintCommand({
    required String command,
    String? fallbackCommand,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Future<void> publishAndAwait(String cmd) async {
      final seq = (_seq++).toString();
      final payload = {
        'print': {'sequence_id': seq, 'command': cmd},
      };
      _log(BambuLogLevel.info, 'MQTT print command request: $cmd seq=$seq');
      final ackFuture = _waitForAck(
        sequenceId: seq,
        command: cmd,
        timeout: timeout,
      );
      await publishRequest(payload);
      final ack = await ackFuture;
      _log(
        BambuLogLevel.info,
        'MQTT print command ACK: command=$cmd envelope=${ack.envelope} '
        'seq=${ack.sequenceId} result=${ack.payload['result'] ?? ''} '
        'reason=${ack.payload['reason'] ?? ''} '
        'error_code=${ack.payload['error_code'] ?? ''}',
      );
      if (_ackIndicatesFailure(ack.payload)) {
        throw StateError(_ackFailureMessage(ack.payload));
      }
    }

    try {
      await publishAndAwait(command);
    } catch (e) {
      if (fallbackCommand == null || fallbackCommand == command) {
        rethrow;
      }
      _log(
        BambuLogLevel.warning,
        'MQTT print command fallback: command=$command reason=$e '
        'fallback=$fallbackCommand',
      );
      await publishAndAwait(fallbackCommand);
    }
  }

  Future<_MqttEnvelopeAck> _waitForAck({
    required String sequenceId,
    String? command,
    Duration timeout = const Duration(seconds: 3),
  }) {
    return _reports.stream
        .map((event) => _extractAckEnvelope(event.json))
        .where((ack) => ack != null)
        .cast<_MqttEnvelopeAck>()
        .firstWhere((ack) {
          if (ack.sequenceId != sequenceId) return false;
          if (command == null) return true;
          final ackCommand = ack.payload['command']?.toString();
          return ackCommand == null || ackCommand == command;
        })
        .timeout(timeout);
  }

  Map<String, dynamic>? _asStringDynamicMap(Object? value) {
    if (value is! Map) return null;
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      out[entry.key.toString()] = entry.value;
    }
    return out;
  }

  _MqttEnvelopeAck? _extractAckEnvelope(Map<String, dynamic> json) {
    for (final envelope in ['print', 'system', 'info', 'pushing']) {
      final payload = _asStringDynamicMap(json[envelope]);
      if (payload == null) continue;
      final seq = payload['sequence_id']?.toString();
      if (seq != null && seq.isNotEmpty) {
        return _MqttEnvelopeAck(
          envelope: envelope,
          sequenceId: seq,
          payload: payload,
        );
      }
    }
    return null;
  }

  bool _ackIndicatesFailure(Map<String, dynamic> payload) {
    final result = payload['result']?.toString();
    final reason = payload['reason']?.toString();
    final errorCode = payload['error_code']?.toString();
    final hasErrorCode =
        errorCode != null && errorCode.isNotEmpty && errorCode.trim() != '0';
    return _isFailureSignal(result) ||
        _isFailureSignal(reason) ||
        hasErrorCode ||
        (reason?.toLowerCase().contains('verification failed') ?? false);
  }

  String _ackFailureMessage(Map<String, dynamic> payload) {
    final reason = payload['reason']?.toString();
    final result = payload['result']?.toString();
    final errorCode = payload['error_code']?.toString();
    if (reason != null && reason.isNotEmpty) return reason;
    if (result != null && result.isNotEmpty) return result;
    if (errorCode != null && errorCode.isNotEmpty) {
      return 'error_code=$errorCode';
    }
    return 'command rejected by printer';
  }

  bool _isFailureSignal(String? value) {
    if (value == null) return false;
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return false;
    return v == 'fail' ||
        v == 'failed' ||
        v == 'error' ||
        v == 'reject' ||
        v == 'rejected' ||
        v == 'failure';
  }
}

class BambuCommandEvent {
  final String topic;
  final Map<String, dynamic> payload;
  final MqttQos qos;
  final DateTime timestamp;
  const BambuCommandEvent({
    required this.topic,
    required this.payload,
    required this.qos,
    required this.timestamp,
  });
}

class _MqttEnvelopeAck {
  final String envelope;
  final String sequenceId;
  final Map<String, dynamic> payload;

  const _MqttEnvelopeAck({
    required this.envelope,
    required this.sequenceId,
    required this.payload,
  });
}

/// Speed profile presets commonly seen on Bambu printers.
enum BambuSpeedProfile { silent, standard, sport, ludicrous }

extension BambuSpeedProfileX on BambuSpeedProfile {
  String get label {
    switch (this) {
      case BambuSpeedProfile.silent:
        return 'Silent';
      case BambuSpeedProfile.standard:
        return 'Standard';
      case BambuSpeedProfile.sport:
        return 'Sport';
      case BambuSpeedProfile.ludicrous:
        return 'Ludicrous';
    }
  }

  /// Conservative percent mappings as a fallback if no native profile API.
  int get fallbackPercent {
    switch (this) {
      case BambuSpeedProfile.silent:
        return 70;
      case BambuSpeedProfile.standard:
        return 100;
      case BambuSpeedProfile.sport:
        return 150;
      case BambuSpeedProfile.ludicrous:
        return 200;
    }
  }

  String get mqttParam {
    switch (this) {
      case BambuSpeedProfile.silent:
        return '1';
      case BambuSpeedProfile.standard:
        return '2';
      case BambuSpeedProfile.sport:
        return '3';
      case BambuSpeedProfile.ludicrous:
        return '4';
    }
  }
}
