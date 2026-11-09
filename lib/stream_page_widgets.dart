import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/connection_preflight.dart';
import 'package:boomprint/printer_firmware.dart';
import 'package:boomprint/settings_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

String? formatNozzleInfo(BambuPrintStatus? ps) {
  if (ps == null) return null;
  final type = ps.nozzleType?.trim() ?? '';
  final diameter = ps.nozzleDiameter?.trim() ?? '';
  if (type.isEmpty && diameter.isEmpty) return null;
  if (type.isNotEmpty && diameter.isNotEmpty) return '$type • $diameter';
  return type.isNotEmpty ? type : diameter;
}

String? formatPrintFileTitle(BambuPrintStatus? ps) {
  if (ps == null) return null;
  final subtask = ps.subtaskName?.trim();
  if (subtask != null && subtask.isNotEmpty) {
    return subtask;
  }
  final gcodeFile = ps.gcodeFile?.trim();
  if (gcodeFile == null || gcodeFile.isEmpty) {
    return null;
  }
  return path.basename(gcodeFile);
}

String? buildTitleSummary(BambuPrintStatus? ps) {
  final lines = <String>[];
  final printFile = formatPrintFileTitle(ps);
  if (printFile != null) {
    lines.add('Print: $printFile');
  }
  final nozzleInfo = formatNozzleInfo(ps);
  if (nozzleInfo != null) {
    lines.add('Nozzle: $nozzleInfo');
  }
  if (lines.isEmpty) return null;
  return lines.join(' • ');
}

bool isPrintPaused(BambuPrintStatus? status) {
  final state = status?.gcodeState.trim().toUpperCase();
  return state == 'PAUSE' || state == 'PAUSED';
}

bool isPrintActive(BambuPrintStatus? status) {
  final state = status?.gcodeState.trim().toUpperCase();
  return state == 'RUNNING' || state == 'PREPARE' || isPrintPaused(status);
}

String printStageLabel(BambuPrintStatus status) {
  final state = status.gcodeState.trim().toUpperCase();
  if (isPrintPaused(status)) return 'Paused';
  if (state == 'FINISH') return 'Finished';
  if (state == 'IDLE') return 'Idle';
  if (status.stage == 2 && state == 'RUNNING' && (status.layer ?? 0) > 0) {
    return 'Printing';
  }
  const stages = <int, String>{
    0: 'Printing',
    1: 'Auto bed leveling',
    2: 'Heating bed',
    3: 'Vibration compensation',
    4: 'Changing filament',
    5: 'Paused by G-code',
    6: 'Paused: filament ran out',
    7: 'Heating nozzle',
    10: 'Inspecting first layer',
    13: 'Homing toolhead',
    16: 'Paused by user',
    20: 'Paused: nozzle temperature',
    21: 'Paused: bed temperature',
    22: 'Unloading filament',
    24: 'Loading filament',
    26: 'Paused: AMS offline',
    32: 'Paused: nozzle clumping',
    33: 'Paused: cutter error',
    34: 'Paused: first-layer error',
    77: 'Preparing AMS',
  };
  return stages[status.stage] ??
      (state.isEmpty || state == 'PRINT' ? 'Printer status updating' : state);
}

class PrintControlButtons extends StatelessWidget {
  final BambuPrintStatus? status;
  final bool mqttConnected;
  final bool busy;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  const PrintControlButtons({
    super.key,
    required this.status,
    required this.mqttConnected,
    required this.busy,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (!isPrintActive(status)) return const SizedBox.shrink();
    final paused = isPrintPaused(status);
    final enabled = mqttConnected && !busy;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: enabled ? (paused ? onResume : onPause) : null,
          icon: busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(paused ? Icons.play_arrow : Icons.pause),
          label: Text(paused ? 'Resume print' : 'Pause print'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? onCancel : null,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Cancel print'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
        ),
      ],
    );
  }
}

class PrinterFaultBanner extends StatefulWidget {
  final BambuPrintStatus status;

  const PrinterFaultBanner({super.key, required this.status});

  @override
  State<PrinterFaultBanner> createState() => _PrinterFaultBannerState();
}

class _PrinterFaultBannerState extends State<PrinterFaultBanner> {
  final Set<String> _dismissed = {};

  @override
  void didUpdateWidget(covariant PrinterFaultBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = _notices().map((notice) => notice.key).toSet();
    // Telemetry updates must not revive a dismissed condition. Clearing it on
    // the printer allows a later recurrence of that condition to appear again.
    _dismissed.retainWhere(active.contains);
  }

  List<_PrinterNotice> _notices() {
    final status = widget.status;
    final notices = <String, _PrinterNotice>{};
    for (final event in status.hms) {
      final key = 'hms:${event.catalogCode}';
      notices[key] = _PrinterNotice(
        key: key,
        message:
            event.knownMessage ??
            'The printer reported a hardware condition with no available '
                'description. Check the printer display for details.',
        code: 'HMS ${event.displayCode}',
        informational: event.isInformational,
        error: event.isError,
      );
    }
    final message = status.printerMessage?.trim();
    if (status.printError != null && status.printError != 0) {
      final hex = status.printError!
          .toRadixString(16)
          .padLeft(8, '0')
          .toUpperCase();
      notices['print:${status.printError}'] = _PrinterNotice(
        key: 'print:${status.printError}',
        message: message?.isNotEmpty == true
            ? message!
            : 'The printer reported a print error. Check the printer display '
                  'for details before continuing.',
        code:
            'Print error ${hex.substring(0, 4)}-${hex.substring(4)} '
            '(${status.printError})',
        error: true,
      );
    } else if (message?.isNotEmpty == true) {
      notices['message:$message'] = _PrinterNotice(
        key: 'message:$message',
        message: message!,
      );
    }
    return notices.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final notice in _notices())
          if (!_dismissed.contains(notice.key))
            Material(
              key: ValueKey(notice.key),
              color: notice.error
                  ? colors.errorContainer
                  : notice.informational
                  ? colors.surfaceContainerHighest
                  : colors.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Icon(
                        notice.error
                            ? Icons.error_outline
                            : notice.informational
                            ? Icons.info_outline
                            : Icons.warning_amber_rounded,
                        color: notice.error
                            ? colors.onErrorContainer
                            : notice.informational
                            ? colors.onSurfaceVariant
                            : colors.onTertiaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(notice.message),
                          if (notice.code != null) ...[
                            const SizedBox(height: 4),
                            SelectableText(
                              notice.code!,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy printer message',
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text: [notice.message, ?notice.code].join('\n'),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Dismiss',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _dismissed.add(notice.key);
                      }),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _PrinterNotice {
  final String key;
  final String message;
  final String? code;
  final bool informational;
  final bool error;

  const _PrinterNotice({
    required this.key,
    required this.message,
    this.code,
    this.informational = false,
    this.error = false,
  });
}

class FilamentStatusPanel extends StatelessWidget {
  final BambuPrintStatus status;

  const FilamentStatusPanel({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final active = status.activeFilament;
    if (active == null) return const SizedBox.shrink();
    final remaining = active.remainingPercent;
    final details = [
      if (active.name?.isNotEmpty == true) active.name!,
      if (active.type?.isNotEmpty == true) active.type!,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Filament', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Row(
              children: [
                if (_trayColor(active.color) case final swatch?) ...[
                  swatch,
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        active.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (details.isNotEmpty)
                        Text(
                          details.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (remaining != null) ...[
                  const SizedBox(width: 12),
                  Text('$remaining%'),
                ],
              ],
            ),
            if (remaining != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: remaining / 100),
            ],
          ],
        ),
      ),
    );
  }

  Widget? _trayColor(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.length != 8) return null;
    final color = int.tryParse(value, radix: 16);
    if (color == null) return null;
    return CircleAvatar(
      radius: 9,
      backgroundColor: Color.fromARGB(
        (color & 0xff).toInt(),
        ((color >> 24) & 0xff).toInt(),
        ((color >> 16) & 0xff).toInt(),
        ((color >> 8) & 0xff).toInt(),
      ),
    );
  }
}

class MetricsPanel extends StatelessWidget {
  final BambuPrintStatus ps;
  const MetricsPanel({super.key, required this.ps});

  @override
  Widget build(BuildContext context) {
    String fmtTemp(double? t) => t == null ? '-' : '${t.toStringAsFixed(0)}°C';
    String fmtRssi(String? s) => s == null || s.isEmpty ? '-' : s;
    String fmtLayer(int? l, int? t) =>
        (l == null && t == null) ? '-' : '${l ?? '?'} / ${t ?? '?'}';
    String fmtSpeed(int? level, int? mag) {
      if (level == null && mag == null) return '-';
      if (level != null && mag != null) return 'L$level ($mag%)';
      if (level != null) return 'L$level';
      return '$mag%';
    }

    final styleValue = Theme.of(context).textTheme.bodySmall;

    Widget item(IconData icon, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 4),
        Text(value, style: styleValue),
      ],
    );

    final items = <Widget>[
      if (ps.nozzleTemp != null || ps.nozzleTarget != null)
        item(
          Icons.local_fire_department,
          '${fmtTemp(ps.nozzleTemp)} / ${fmtTemp(ps.nozzleTarget)}',
        ),
      if (ps.bedTemp != null || ps.bedTarget != null)
        item(
          Icons.grid_on,
          '${fmtTemp(ps.bedTemp)} / ${fmtTemp(ps.bedTarget)}',
        ),
      if (ps.chamberTemp != null)
        item(Icons.crop_square, fmtTemp(ps.chamberTemp)),
      if (ps.speedLevel != null || ps.speedMag != null)
        item(Icons.speed, fmtSpeed(ps.speedLevel, ps.speedMag)),
      if (ps.wifiSignal != null && ps.wifiSignal!.isNotEmpty)
        item(Icons.wifi, fmtRssi(ps.wifiSignal)),
      if (ps.layer != null || ps.totalLayers != null)
        item(Icons.layers, fmtLayer(ps.layer, ps.totalLayers)),
      if (ps.percent != null) item(Icons.percent, '${ps.percent}%'),
      if (ps.remainingMinutes != null)
        item(Icons.timelapse, '${ps.remainingMinutes}m'),
    ];

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Wrap(spacing: 12, runSpacing: 6, children: items),
      ),
    );
  }
}

class PrintOverlayStatus extends StatelessWidget {
  final BambuPrintStatus? status;
  const PrintOverlayStatus({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            'Waiting for MQTT status…',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      );
    }

    final parts = <String>[];
    parts.add(printStageLabel(status!));
    if (status!.percent != null) {
      parts.add('${status!.percent}%');
    }
    if (status!.remainingMinutes != null) {
      parts.add('${status!.remainingMinutes}m left');
    }
    if (status!.layer != null || status!.totalLayers != null) {
      final layer = status!.layer?.toString() ?? '?';
      final total = status!.totalLayers?.toString() ?? '?';
      parts.add('Layer $layer / $total');
    }
    if (parts.isEmpty) {
      return const SizedBox.shrink();
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          parts.join(' • '),
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }
}

class FirmwareWarningBanner extends StatelessWidget {
  final PrinterFirmwareWarning warning;
  final VoidCallback? onOpenHelp;

  const FirmwareWarningBanner({
    super.key,
    required this.warning,
    this.onOpenHelp,
  });

  @override
  Widget build(BuildContext context) {
    final helpUrl = warning.helpEntry.links.isNotEmpty
        ? warning.helpEntry.links.first.url
        : null;
    return MaterialBanner(
      backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
      leading: Icon(
        Icons.warning_amber_rounded,
        color: Theme.of(context).colorScheme.onTertiaryContainer,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Firmware may be too old',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            warning.message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
          ),
          if (warning.firmwareVersion.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Detected firmware: ${warning.firmwareVersion}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onTertiaryContainer,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (helpUrl != null)
          TextButton(
            onPressed: onOpenHelp,
            child: const Text('Firmware updates'),
          ),
      ],
    );
  }
}

class DisconnectedBody extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final Future<void> Function(String url) onConnect;

  const DisconnectedBody({
    super.key,
    required this.onOpenSettings,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No active stream',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onOpenSettings,
            child: const Text('Configure Stream'),
          ),
          ElevatedButton(
            onPressed: () async {
              final settings = SettingsManager.settings;
              final streamUrl = ConnectionPreflight.buildStreamUrl(settings);
              if (streamUrl.trim().isEmpty) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please configure printer settings first'),
                    ),
                  );
                }
                return;
              }

              final summary = await ConnectionPreflight.run(
                settings: settings,
                streamUrl: streamUrl,
              );
              if (!context.mounted) return;

              if (summary.hasRequiredFailures) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(summary.summaryLine)));
                return;
              }

              final optionalFailures = summary.optionalFailures.toList();
              if (optionalFailures.isNotEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Printer stream is reachable. ${optionalFailures.map((r) => r.label).join(', ')} unavailable, but optional.',
                    ),
                  ),
                );
              }

              await onConnect(streamUrl);
            },
            child: const Text('Connect to Printer'),
          ),
        ],
      ),
    );
  }
}
