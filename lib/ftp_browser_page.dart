import 'dart:async';
import 'dart:io';

import 'package:boomprint/feature_flags.dart';
import 'package:boomprint/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:boomprint/bambu_ftp.dart';
import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/bambu_mqtt.dart';
import 'package:boomprint/log_redaction.dart';
import 'package:boomprint/settings_manager.dart';
import 'package:three_mf/three_mf.dart';
import 'window_drag_controller.dart';

enum _FtpEntrySort { modifiedNewest, modifiedOldest, name, sizeLargest }

enum _FtpFileFilter { printable, videos, all }

class FtpBrowserPage extends StatefulWidget {
  const FtpBrowserPage({super.key});

  @override
  State<FtpBrowserPage> createState() => _FtpBrowserPageState();
}

class _FtpBrowserPageState extends State<FtpBrowserPage> {
  late BambuFtp _ftp;
  BambuMqtt? _mqtt;
  String _cwd = '/';
  List<FtpEntry> _entries = const [];
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';
  _FtpEntrySort _sort = _FtpEntrySort.modifiedNewest;
  _FtpFileFilter _fileFilter = _FtpFileFilter.printable;
  bool _loading = true;
  String? _selectedFile;
  String _status = '';
  FilamentOption? _selectedFilament;
  List<FilamentOption> _filamentOptions = const [];
  ThreeMfProjectInfo? _selectedThreeMfInfo;
  bool _loadingThreeMfInfo = false;
  String? _selectedThreeMfPath;
  String? _currentNozzleDiameter;
  String? _currentNozzleType;
  final List<String> _printDebugLog = <String>[];
  String? _pendingPrintSeq;
  bool _submittingPrint = false;
  bool _timelapse = true;
  bool _bedLevelling = true;
  bool _flowCalibration = true;
  bool _vibrationCalibration = true;
  bool _layerInspection = true;
  int _pendingReportCount = 0;
  Timer? _pendingPrintTimer;
  StreamSubscription<BambuReportEvent>? _mqttReportSub;
  StreamSubscription<BambuCommandEvent>? _mqttCommandSub;

  void _setStateIfMounted(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  @override
  void initState() {
    super.initState();
    if (!FeatureFlags.ftpBrowserEnabled) {
      _loading = false;
      _status = 'FTP Browser is disabled by feature flag.';
      return;
    }
    _initConnections();
  }

  Future<void> _initConnections() async {
    _setStateIfMounted(() => _loading = true);
    final s = await SettingsManager.loadSettings();
    final cfg = BambuLanConfig(
      printerIp: s.printerIp,
      accessCode: s.specialCode,
      serial: s.serialNumber,
      allowBadCerts: true,
      mqttPort: 8883,
    );
    _ftp = BambuFtp(cfg);
    try {
      // MQTT optional; connect to pull filament info & print status.
      final mqtt = BambuMqtt(cfg);
      await mqtt.connect();
      _mqtt = mqtt;
      _subscribeMqtt(mqtt);
      mqtt.requestPushAll().catchError((_) {});
    } catch (_) {
      // keep browsing; printing will try to reconnect
    }
    await _refresh();
  }

  void _subscribeMqtt(BambuMqtt mqtt) {
    _mqttReportSub?.cancel();
    _mqttCommandSub?.cancel();

    _mqttReportSub = mqtt.reportStream.listen((event) {
      _handleMqttReport(event);
    });

    _mqttCommandSub = mqtt.commandStream.listen((event) {
      final payload = _asStringDynamicMap(event.payload['print']);
      if (payload != null && payload['command'] != null) {
        final cmd = payload['command']?.toString() ?? '?';
        final seq = payload['sequence_id']?.toString() ?? '?';
        final param = payload['param']?.toString();
        final url = payload['url']?.toString();
        final useAms = payload['use_ams'];
        final ams = payload['ams_mapping'];
        _logPrintDebug('CMD $cmd seq=$seq topic=${event.topic}');
        if (param != null && param.isNotEmpty) {
          _logPrintDebug('  param=$param');
        }
        if (url != null && url.isNotEmpty) {
          _logPrintDebug('  url=$url');
        }
        if (useAms != null) {
          _logPrintDebug('  use_ams=$useAms');
        }
        if (ams is List && ams.isNotEmpty) {
          _logPrintDebug('  ams_mapping=$ams');
        }
      }
    });
  }

  void _logPrintDebug(String message) {
    message = redactLogText(
      message,
      secrets: [
        SettingsManager.settings.specialCode,
        SettingsManager.settings.genericRtspPassword,
      ],
    );
    final ts = DateTime.now().toIso8601String();
    debugPrint('[FTP PRINT $ts] $message');
    _setStateIfMounted(() {
      _printDebugLog.insert(0, '$ts $message');
      if (_printDebugLog.length > 100) {
        _printDebugLog.removeRange(100, _printDebugLog.length);
      }
    });
  }

  Future<void> _copyPrintDebug() async {
    final text = [
      if (_status.isNotEmpty)
        redactLogText(
          _status,
          secrets: [
            SettingsManager.settings.specialCode,
            SettingsManager.settings.genericRtspPassword,
          ],
        ),
      ..._printDebugLog.reversed,
    ].join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Print debug log copied.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to copy print debug log.')),
      );
    }
  }

  Future<void> _inspectSelectedThreeMf(String remotePath) async {
    _setStateIfMounted(() {
      _loadingThreeMfInfo = true;
      _selectedThreeMfPath = remotePath;
      _selectedThreeMfInfo = null;
    });

    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('boomprint_3mf_');
      final basename = remotePath.split('/').last;
      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}$basename',
      );
      final downloaded = await _ftp.downloadFile(remotePath, localFile);
      if (!downloaded) {
        throw StateError('FTP download failed');
      }

      final parser = ThreeMfParser();
      final info = await parser.parseBytes(await localFile.readAsBytes());
      if (!mounted || _selectedThreeMfPath != remotePath) return;

      _setStateIfMounted(() {
        _selectedThreeMfInfo = info;
        _loadingThreeMfInfo = false;
        if (info != null) {
          final matched = _matchFilamentOption(info);
          if (matched != null && info.orderedFilaments.length <= 1) {
            _selectedFilament = matched;
          }
        }
      });
    } catch (e) {
      if (!mounted || _selectedThreeMfPath != remotePath) return;
      _setStateIfMounted(() {
        _selectedThreeMfInfo = null;
        _loadingThreeMfInfo = false;
      });
      _logPrintDebug('3MF inspect failed for $remotePath: $e');
    } finally {
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  FilamentOption? _matchFilamentOption(ThreeMfProjectInfo info) {
    final hints =
        [
              ...info.filamentHints,
              ...info.plates.expand((plate) => plate.filamentHints),
            ]
            .map((value) => value.toLowerCase())
            .where((value) => value.isNotEmpty)
            .toList();
    if (hints.isEmpty) return null;

    for (final option in _filamentOptions) {
      final label = option.label.toLowerCase();
      if (hints.any((hint) => label.contains(hint.toLowerCase()))) {
        return option;
      }
    }
    return null;
  }

  void _handleMqttReport(BambuReportEvent event) {
    final print = _asStringDynamicMap(event.json['print']);
    if (print != null) {
      final options = _extractFilamentOptions(print);
      if (options.isNotEmpty) {
        _setStateIfMounted(() {
          _filamentOptions = options;
          _selectedFilament ??= _selectCurrentFilament(print, options);
          if (_selectedFilament == null && _selectedThreeMfInfo != null) {
            _selectedFilament = _matchFilamentOption(_selectedThreeMfInfo!);
          }
        });
      }

      final printStatus = event.printStatus;
      if (printStatus != null) {
        _setStateIfMounted(() {
          _currentNozzleDiameter = printStatus.nozzleDiameter;
          _currentNozzleType = printStatus.nozzleType;
        });
      }
    }

    if (_pendingPrintSeq != null && _pendingReportCount < 12) {
      _pendingReportCount += 1;
      _logPrintDebug(
        'RPT #$_pendingReportCount topic=${event.topic} '
        '${_summarizeReportEnvelope(event.json)}',
      );
    }

    final ack = _extractAckEnvelope(event.json);
    if (_pendingPrintSeq == null || ack == null) {
      return;
    }
    if (ack.sequenceId != _pendingPrintSeq) {
      return;
    }

    final cmd = ack.payload['command']?.toString() ?? ack.envelope;
    final result = ack.payload['result']?.toString();
    final reason = ack.payload['reason']?.toString();
    final errCode = ack.payload['error_code']?.toString();
    _logPrintDebug(
      'ACK $cmd seq=${ack.sequenceId} '
      '${result != null ? 'result=$result ' : ''}'
      '${reason != null && reason.isNotEmpty ? 'reason=$reason ' : ''}'
      '${errCode != null && errCode.isNotEmpty ? 'error_code=$errCode' : ''}'
      '(env=${ack.envelope})',
    );

    final hasErrorCode =
        errCode != null && errCode.isNotEmpty && errCode.trim() != '0';
    final failed =
        _isFailureSignal(result) || _isFailureSignal(reason) || hasErrorCode;
    if (failed) {
      final msg =
          reason ??
          result ??
          (errCode != null && errCode.isNotEmpty
              ? 'error_code=$errCode'
              : 'printer rejected command');
      _setStateIfMounted(() => _status = 'Print rejected: $msg');
    } else {
      _setStateIfMounted(() => _status = 'Print command acknowledged.');
    }
    _clearPendingPrint();
  }

  void _clearPendingPrint() {
    _pendingPrintSeq = null;
    _pendingReportCount = 0;
    _pendingPrintTimer?.cancel();
    _pendingPrintTimer = null;
  }

  bool _isPrintablePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.gcode') || lower.endsWith('.3mf');
  }

  bool _isVideoPath(String path) {
    const extensions = <String>[
      '.mp4',
      '.m4v',
      '.mkv',
      '.mov',
      '.avi',
      '.webm',
    ];
    final lower = path.toLowerCase();
    return extensions.any(lower.endsWith);
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

  String _summarizeReportEnvelope(Map<String, dynamic> json) {
    final topKeys = json.keys.take(6).join(',');
    final print = _asStringDynamicMap(json['print']);
    if (print == null) {
      return 'top=[$topKeys]';
    }
    final cmd = print['command']?.toString();
    final seq = print['sequence_id']?.toString();
    final state = print['gcode_state']?.toString();
    final pct = print['mc_percent']?.toString();
    final result = print['result']?.toString();
    final reason = print['reason']?.toString();
    final details = <String>[
      if (cmd != null && cmd.isNotEmpty) 'cmd=$cmd',
      if (seq != null && seq.isNotEmpty) 'seq=$seq',
      if (state != null && state.isNotEmpty) 'state=$state',
      if (pct != null && pct.isNotEmpty) 'pct=$pct',
      if (result != null && result.isNotEmpty) 'result=$result',
      if (reason != null && reason.isNotEmpty) 'reason=$reason',
    ];
    return 'top=[$topKeys] ${details.join(' ')}';
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
        v == 'denied' ||
        v == 'invalid' ||
        v == 'forbidden' ||
        v == 'timeout' ||
        v == 'busy';
  }

  FilamentOption? _resolveSelectedFilament() {
    final current = _selectedFilament;
    if (current == null) return null;
    for (final opt in _filamentOptions) {
      if (opt.id == current.id) return opt;
    }
    return null;
  }

  int? _trayIndexFromFilament(FilamentOption? filament) {
    if (filament == null) return null;
    return filament.trayIndex;
  }

  List<int> _singleColorAmsMapping(int trayIndex) {
    // project_file expects a fixed-width mapping array; right-most entry is
    // consumed first for single-color jobs.
    return <int>[-1, -1, -1, -1, trayIndex];
  }

  Future<void> _refresh() async {
    _setStateIfMounted(() => _loading = true);
    try {
      final list = await _ftp.list(_cwd);
      _setStateIfMounted(() {
        _entries = list;
        _status = '';
      });
    } on TimeoutException catch (e) {
      _setStateIfMounted(
        () => _status = 'FTP timed out: ${e.message ?? 'request stalled'}',
      );
    } catch (e) {
      _setStateIfMounted(() => _status = 'List failed: $e');
    } finally {
      _setStateIfMounted(() => _loading = false);
    }
  }

  List<FtpEntry> get _visibleEntries {
    final query = _filter.trim();
    final entries = _entries.where((entry) {
      if (!entry.isDir && !_matchesFileFilter(entry.path)) {
        return false;
      }
      return _matchesFuzzyQuery('${entry.name} ${entry.path}', query);
    }).toList();
    entries.sort(_compareEntries);
    return entries;
  }

  bool _matchesFileFilter(String path) => switch (_fileFilter) {
    _FtpFileFilter.printable => _isPrintablePath(path),
    _FtpFileFilter.videos => _isVideoPath(path),
    _FtpFileFilter.all => true,
  };

  bool _matchesFuzzyQuery(String candidate, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return true;

    final normalizedCandidate = candidate.toLowerCase();
    return normalizedQuery
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .every(
          (term) =>
              normalizedCandidate.contains(term) ||
              _containsCharactersInOrder(normalizedCandidate, term),
        );
  }

  bool _containsCharactersInOrder(String candidate, String query) {
    var candidateIndex = 0;
    for (final codeUnit in query.codeUnits) {
      candidateIndex = candidate.indexOf(
        String.fromCharCode(codeUnit),
        candidateIndex,
      );
      if (candidateIndex < 0) return false;
      candidateIndex += 1;
    }
    return true;
  }

  String _fileFilterLabel(_FtpFileFilter filter) => switch (filter) {
    _FtpFileFilter.printable => 'Printable',
    _FtpFileFilter.videos => 'Videos',
    _FtpFileFilter.all => 'All files',
  };

  int _compareEntries(FtpEntry a, FtpEntry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    final result = switch (_sort) {
      _FtpEntrySort.name => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      _FtpEntrySort.modifiedNewest => _compareNullableInt(
        b.modified?.millisecondsSinceEpoch,
        a.modified?.millisecondsSinceEpoch,
      ),
      _FtpEntrySort.modifiedOldest => _compareNullableInt(
        a.modified?.millisecondsSinceEpoch,
        b.modified?.millisecondsSinceEpoch,
      ),
      _FtpEntrySort.sizeLargest => _compareNullableInt(b.size, a.size),
    };
    return result != 0
        ? result
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  int _compareNullableInt(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  String _sortLabel(_FtpEntrySort sort) => switch (sort) {
    _FtpEntrySort.modifiedNewest => 'Modified: newest',
    _FtpEntrySort.modifiedOldest => 'Modified: oldest',
    _FtpEntrySort.name => 'Name',
    _FtpEntrySort.sizeLargest => 'Size: largest',
  };

  String _entryMetadata(BuildContext context, FtpEntry entry) {
    final parts = <String>[];
    final modified = entry.modified;
    if (modified != null) {
      final localizations = MaterialLocalizations.of(context);
      parts.add(
        'Modified ${localizations.formatMediumDate(modified)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(modified))}',
      );
    }
    if (!entry.isDir && entry.size != null) {
      parts.add(_formatBytes(entry.size!));
    }
    return parts.join(' • ');
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final precision = value < 10 && unit > 0 ? 1 : 0;
    return '${value.toStringAsFixed(precision)} ${units[unit]}';
  }

  Future<void> _enter(FtpEntry e) async {
    if (!e.isDir) {
      _setStateIfMounted(() => _selectedFile = e.path);
      if (_isPrintablePath(e.path) && e.path.toLowerCase().endsWith('.3mf')) {
        await _inspectSelectedThreeMf(e.path);
      } else {
        _setStateIfMounted(() {
          _selectedThreeMfInfo = null;
          _loadingThreeMfInfo = false;
          _selectedThreeMfPath = null;
        });
      }
      return;
    }
    _setStateIfMounted(() {
      _cwd = e.path;
      _selectedFile = null;
      _selectedThreeMfInfo = null;
      _loadingThreeMfInfo = false;
      _selectedThreeMfPath = null;
    });
    await _refresh();
  }

  Future<void> _up() async {
    if (_cwd == '/' || _cwd.isEmpty) return;
    final parts = _cwd.split('/')..removeWhere((p) => p.isEmpty);
    if (parts.isNotEmpty) parts.removeLast();
    final parent = parts.isEmpty ? '/' : '/${parts.join('/')}';
    _setStateIfMounted(() {
      _cwd = parent;
      _selectedFile = null;
      _selectedThreeMfInfo = null;
      _loadingThreeMfInfo = false;
      _selectedThreeMfPath = null;
    });
    await _refresh();
  }

  Future<void> _startPrint() async {
    if (_submittingPrint || _pendingPrintSeq != null || _loadingThreeMfInfo) {
      return;
    }
    final file = _selectedFile;
    if (file == null) return;
    if (!_isPrintablePath(file)) {
      _setStateIfMounted(() => _status = 'Select a .gcode or .3mf file.');
      return;
    }
    setState(() => _submittingPrint = true);
    try {
      var mqtt = _mqtt;
      if (mqtt == null || !mqtt.isConnected) {
        final s = await SettingsManager.loadSettings();
        final cfg = BambuLanConfig(
          printerIp: s.printerIp,
          accessCode: s.specialCode,
          serial: s.serialNumber,
          allowBadCerts: true,
          mqttPort: 8883,
        );
        mqtt = BambuMqtt(cfg);
        await mqtt.connect();
        _mqtt = mqtt;
        _subscribeMqtt(mqtt);
        mqtt.requestPushAll().catchError((_) {});
      }
      final lowerFile = file.toLowerCase();
      final isGcode = lowerFile.endsWith('.gcode');
      final cmd = isGcode ? 'gcode_file' : 'project_file';
      final selectedFilament = _resolveSelectedFilament();
      final filament = selectedFilament?.label;
      _logPrintDebug(
        'PRINT request: $cmd file=$file'
        '${filament != null ? ' | filament=$filament' : ''}',
      );
      late final String seq;
      if (isGcode) {
        seq = await _mqtt!.printGcodeFile(file);
      } else {
        if (selectedFilament == null) {
          _setStateIfMounted(
            () => _status =
                'Select a filament option before starting a .3mf print.',
          );
          _logPrintDebug(
            'PRINT blocked: no filament selected for project_file.',
          );
          return;
        }
        final trayIndex = _trayIndexFromFilament(selectedFilament);
        final useAms = selectedFilament.id != 'external';
        if (useAms && trayIndex == null) {
          _setStateIfMounted(
            () => _status = 'Selected filament is invalid for AMS mapping.',
          );
          _logPrintDebug(
            'PRINT blocked: invalid AMS mapping for ${selectedFilament.id}.',
          );
          return;
        }
        final mapping = useAms ? _singleColorAmsMapping(trayIndex!) : <int>[];
        seq = await _mqtt!.printProjectFile(
          projectPath: file,
          plateIndex: 1,
          amsMapping: mapping,
          useAms: useAms,
          timelapse: _timelapse,
          bedLevelling: _bedLevelling,
          flowCalibration: _flowCalibration,
          vibrationCalibration: _vibrationCalibration,
          layerInspection: _layerInspection,
        );
      }
      _pendingPrintSeq = seq;
      _pendingReportCount = 0;
      _pendingPrintTimer?.cancel();
      _pendingPrintTimer = Timer(const Duration(seconds: 15), () {
        if (!mounted) return;
        if (_pendingPrintSeq != null) {
          final pendingSeq = _pendingPrintSeq;
          _logPrintDebug('No matching print ACK after 15s (seq=$pendingSeq).');
          _setStateIfMounted(
            () => _status =
                'Printer acknowledgement timed out. Check the '
                'printer before sending another print request.',
          );
          _clearPendingPrint();
        }
      });
      _setStateIfMounted(
        () => _status =
            'Print requested: ${file.split('/').last} (waiting for ACK)',
      );
    } catch (e) {
      _setStateIfMounted(() => _status = 'Start print failed: $e');
      _logPrintDebug('ERROR start print: $e');
    } finally {
      _setStateIfMounted(() => _submittingPrint = false);
    }
  }

  Widget _buildPrintPreparation() {
    final enabled = !_submittingPrint && _pendingPrintSeq == null;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.tune),
      title: const Text('Print preparation'),
      children: [
        for (final option in [
          ('Bed levelling', _bedLevelling, (bool v) => _bedLevelling = v),
          (
            'Flow calibration',
            _flowCalibration,
            (bool v) => _flowCalibration = v,
          ),
          (
            'Vibration calibration',
            _vibrationCalibration,
            (bool v) => _vibrationCalibration = v,
          ),
          (
            'First-layer inspection',
            _layerInspection,
            (bool v) => _layerInspection = v,
          ),
          ('Timelapse', _timelapse, (bool v) => _timelapse = v),
        ])
          CheckboxListTile(
            dense: true,
            title: Text(option.$1),
            value: option.$2,
            onChanged: enabled
                ? (value) => setState(() => option.$3(value!))
                : null,
          ),
      ],
    );
  }

  Widget _buildThreeMfMetadataPanel() {
    final selectedFile = _selectedFile;
    if (selectedFile == null || !selectedFile.toLowerCase().endsWith('.3mf')) {
      return const SizedBox.shrink();
    }

    final info = _selectedThreeMfInfo;
    if (_loadingThreeMfInfo || _selectedThreeMfPath != selectedFile) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }

    if (info == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'No embedded 3MF metadata was extracted from this project.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final currentNozzle = _currentNozzleLabel;
    final projectNozzles = info.nozzleSummary;
    final nozzleMismatchWarning = _buildNozzleMismatchWarning(info);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Print details',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              if (info.projectName != null && info.projectName!.isNotEmpty)
                Text('Project: ${info.projectName}'),
              if (info.printerProfile != null &&
                  info.printerProfile!.isNotEmpty)
                Text('Printer profile: ${info.printerProfile}'),
              if (info.plateSummaries.isNotEmpty)
                Text('Plates: ${info.plateSummaries.join(' | ')}'),
              if (projectNozzles != null)
                Text('Slicer nozzle: $projectNozzles mm'),
              if (currentNozzle != null) Text('Printer nozzle: $currentNozzle'),
              if (nozzleMismatchWarning != null) ...[
                const SizedBox(height: 6),
                Text(
                  nozzleMismatchWarning,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              for (final warning in info.warnings) ...[
                const SizedBox(height: 4),
                Text(warning, style: const TextStyle(color: Colors.grey)),
              ],
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  info.notes.join(' • '),
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? get _currentNozzleLabel {
    final diameter = _currentNozzleDiameter?.trim() ?? '';
    final type = _currentNozzleType?.trim() ?? '';
    if (diameter.isEmpty && type.isEmpty) return null;
    if (diameter.isNotEmpty && type.isNotEmpty) {
      return '$type $diameter mm';
    }
    return diameter.isNotEmpty ? '$diameter mm' : type;
  }

  String? _buildNozzleMismatchWarning(ThreeMfProjectInfo info) {
    final projectNozzles = info.nozzleHints
        .map(_normalizeNozzleText)
        .where((value) => value.isNotEmpty)
        .toSet();
    final current = _currentNozzleDiameter?.trim() ?? '';
    if (projectNozzles.isEmpty || current.isEmpty) return null;

    final normalizedCurrent = _normalizeNozzleText(current);
    if (normalizedCurrent.isEmpty) return null;

    if (projectNozzles.contains(normalizedCurrent)) {
      return null;
    }

    return 'Slicer nozzle ${projectNozzles.join(', ')} mm does not match the printer nozzle $current mm.';
  }

  String _normalizeNozzleText(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return '';
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(normalized);
    return match?.group(1) ?? '';
  }

  @override
  void dispose() {
    _filterController.dispose();
    _mqtt?.dispose();
    _ftp.dispose();
    _mqttReportSub?.cancel();
    _mqttCommandSub?.cancel();
    _pendingPrintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!FeatureFlags.ftpBrowserEnabled) {
      return FramelessWindowResizeFrame(
        child: Scaffold(
          appBar: WindowChromeHeader(
            title: const Text(AppStrings.appDisplayName),
            subtitle: const Text('FTP Browser'),
            leading: IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          body: const Center(
            child: Text('FTP Browser is disabled for this build.'),
          ),
        ),
      );
    }

    final selected = _selectedFile;
    final selectedPrintable = selected != null && _isPrintablePath(selected);
    final visibleEntries = _visibleEntries;

    return FramelessWindowResizeFrame(
      child: Scaffold(
        appBar: WindowChromeHeader(
          title: const Text(AppStrings.appDisplayName),
          subtitle: const Text('FTP Browser'),
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          actions: [
            PopupMenuButton<_FtpEntrySort>(
              tooltip: 'Sort files',
              icon: const Icon(Icons.sort),
              onSelected: (sort) => setState(() => _sort = sort),
              itemBuilder: (context) => _FtpEntrySort.values
                  .map(
                    (sort) => CheckedPopupMenuItem<_FtpEntrySort>(
                      value: sort,
                      checked: sort == _sort,
                      child: Text(_sortLabel(sort)),
                    ),
                  )
                  .toList(),
            ),
            IconButton(
              tooltip: 'Refresh files',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  ElevatedButton(onPressed: _up, child: const Text('Up')),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _cwd,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextField(
                controller: _filterController,
                onChanged: (value) => setState(() => _filter = value),
                decoration: InputDecoration(
                  labelText: 'Search files',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _filter.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear filter',
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _filterController.clear();
                            setState(() => _filter = '');
                          },
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: SegmentedButton<_FtpFileFilter>(
                segments: const [
                  ButtonSegment(
                    value: _FtpFileFilter.printable,
                    icon: Icon(Icons.print_outlined),
                    label: Text('Printable'),
                  ),
                  ButtonSegment(
                    value: _FtpFileFilter.videos,
                    icon: Icon(Icons.movie_outlined),
                    label: Text('Videos'),
                  ),
                  ButtonSegment(
                    value: _FtpFileFilter.all,
                    icon: Icon(Icons.folder_open_outlined),
                    label: Text('All files'),
                  ),
                ],
                selected: <_FtpFileFilter>{_fileFilter},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _fileFilter = selection.first);
                },
              ),
            ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (visibleEntries.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    _filter.isEmpty
                        ? 'No ${_fileFilterLabel(_fileFilter).toLowerCase()} in this folder.'
                        : 'No ${_fileFilterLabel(_fileFilter).toLowerCase()} match "$_filter".',
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: visibleEntries.length,
                  itemBuilder: (context, i) {
                    final e = visibleEntries[i];
                    final isSel = _selectedFile == e.path;
                    final metadata = _entryMetadata(context, e);
                    return ListTile(
                      leading: Icon(
                        e.isDir
                            ? Icons.folder
                            : _isPrintablePath(e.name)
                            ? Icons.print_outlined
                            : _isVideoPath(e.name)
                            ? Icons.movie_outlined
                            : Icons.insert_drive_file,
                      ),
                      title: Text(e.name.isEmpty ? e.path : e.name),
                      subtitle: metadata.isEmpty ? null : Text(metadata),
                      dense: true,
                      selected: isSel,
                      onTap: () => _enter(e),
                      trailing: !e.isDir && _isPrintablePath(e.name)
                          ? const Text(
                              'printable',
                              style: TextStyle(color: Colors.green),
                            )
                          : !e.isDir && _isVideoPath(e.name)
                          ? const Text('video')
                          : null,
                    );
                  },
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selectedFile == null
                              ? 'Select a .gcode/.3mf to print'
                              : selectedPrintable
                              ? 'Selected: ${_selectedFile!.split('/').last}'
                              : 'Selected (not printable): ${_selectedFile!.split('/').last}',
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed:
                            selectedPrintable &&
                                !_submittingPrint &&
                                _pendingPrintSeq == null &&
                                !_loadingThreeMfInfo
                            ? _startPrint
                            : null,
                        icon: const Icon(Icons.print_outlined),
                        label: Text(
                          _submittingPrint
                              ? 'Sending...'
                              : _pendingPrintSeq != null
                              ? 'Awaiting printer'
                              : 'Start Print',
                        ),
                      ),
                    ],
                  ),
                  _buildThreeMfMetadataPanel(),
                  if (_selectedFile?.toLowerCase().endsWith('.3mf') == true)
                    _buildPrintPreparation(),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Printer filament: '),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<FilamentOption>(
                          isExpanded: true,
                          initialValue: _resolveSelectedFilament(),
                          decoration: const InputDecoration(
                            hintText: 'Select filament',
                          ),
                          items: _filamentOptions
                              .map(
                                (f) => DropdownMenuItem<FilamentOption>(
                                  value: f,
                                  child: Row(
                                    children: [
                                      if (f.color != null)
                                        Container(
                                          width: 12,
                                          height: 12,
                                          margin: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: f.color,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.black26,
                                            ),
                                          ),
                                        ),
                                      Expanded(
                                        child: Text(
                                          f.label,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _selectedFilament = v),
                        ),
                      ),
                    ],
                  ),
                  if (_printDebugLog.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Print debug',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy print debug log',
                          icon: const Icon(Icons.copy),
                          onPressed: _copyPrintDebug,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ..._printDebugLog.take(8).map(
                      (line) => SelectableText(
                        line,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ],
                  if (_status.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(_status, style: const TextStyle(color: Colors.grey)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FilamentOption {
  final String id;
  final String label;
  final Color? color;
  final int? trayIndex;

  const FilamentOption({
    required this.id,
    required this.label,
    this.color,
    this.trayIndex,
  });

  @override
  bool operator ==(Object other) {
    return other is FilamentOption && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
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

List<FilamentOption> _extractFilamentOptions(Map print) {
  final options = <FilamentOption>[];
  final amsContainer = print['ams'];
  if (amsContainer is Map) {
    final amsList = amsContainer['ams'];
    if (amsList is List) {
      for (var amsIndex = 0; amsIndex < amsList.length; amsIndex++) {
        final ams = amsList[amsIndex];
        if (ams is! Map) continue;
        final trayList = ams['tray'];
        if (trayList is List) {
          for (final tray in trayList) {
            if (tray is! Map) continue;
            final trayId = tray['id']?.toString() ?? '';
            if (trayId.isEmpty) continue;
            final trayIdNum = int.tryParse(trayId);
            if (trayIdNum == null) continue;
            if (tray.keys.length == 1 && trayId == '0') {
              // Empty tray entry.
              continue;
            }
            final trayType = tray['tray_type']?.toString() ?? '';
            final trayName = tray['tray_id_name']?.toString() ?? '';
            final trayColor = _parseTrayColor(tray['tray_color']?.toString());
            final trayIndex = (amsIndex * 4) + trayIdNum;
            final labelParts = <String>[
              'AMS ${amsIndex + 1} / Slot $trayId',
              if (trayType.isNotEmpty) trayType,
              if (trayName.isNotEmpty) trayName,
            ];
            options.add(
              FilamentOption(
                id: 'ams:$amsIndex:$trayId',
                label: labelParts.join(' • '),
                color: trayColor,
                trayIndex: trayIndex,
              ),
            );
          }
        }
      }
    }
  }

  final vtTray = print['vt_tray'];
  if (vtTray is Map) {
    options.add(const FilamentOption(id: 'external', label: 'External Spool'));
  }

  return options;
}

Color? _parseTrayColor(String? value) {
  if (value == null) return null;
  final hex = value.trim();
  if (hex.length != 8) return null; // RRGGBBAA
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  final r = (parsed >> 24) & 0xFF;
  final g = (parsed >> 16) & 0xFF;
  final b = (parsed >> 8) & 0xFF;
  final a = parsed & 0xFF;
  return Color.fromARGB(a, r, g, b);
}

FilamentOption? _selectCurrentFilament(
  Map print,
  List<FilamentOption> options,
) {
  final trayNow = print['tray_now']?.toString();
  if (trayNow == null || trayNow.isEmpty || trayNow == '255') return null;
  final trayNum = int.tryParse(trayNow);
  if (trayNum == null) return null;
  if (trayNum == 254) {
    for (final opt in options) {
      if (opt.id == 'external') return opt;
    }
    return null;
  }
  try {
    return options.firstWhere((o) => o.trayIndex == trayNum);
  } catch (_) {
    return null;
  }
}
