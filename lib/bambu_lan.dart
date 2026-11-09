// lib/bambu_lan.dart
// -------------------
// High-level LAN client for Bambu printers: MQTT (telemetry + control)
// and FTP/FTPS (SD-card file operations). Works in Dart VM / Flutter.
//
// Usage sketch (see example/main.dart below for a runnable snippet):
//   final lan = BambuLan(
//     config: BambuLanConfig(
//       printerIp: '192.168.1.50',
//       accessCode: 'YOUR_LAN_ACCESS_CODE',
//       serial: '00Mxxxxxxxxxxxx', // optional for wildcard sub
//       allowBadCerts: false,
//       // caCertPem: await rootBundle.loadString('assets/printer_ca.pem'),
//     ),
//   );
//   await lan.connect();
//   final sub = lan.reportStream.listen((e) { print('Report: ${e.type} ${e.json}'); });
//   final entries = await lan.ftp.list('/');
//   await lan.ftp.upload(localPath: 'job.3mf', remotePath: '/sdcard/job/job.3mf');
//   await lan.mqtt.startPrintFromSd('/sdcard/job/job.3mf');
//   ...

import 'dart:async';

import 'package:boomprint/bambu_hms_catalog.g.dart';
import 'package:boomprint/bambu_mqtt.dart';

// ============================
// Configuration & Public Types
// ============================

class BambuLanConfig {
  final String printerIp;
  final String accessCode; // LAN access code entered on the printer
  final String? serial; // Printer serial (USN); optional for wildcard subscribe

  /// If true, accept self-signed/unknown TLS certs for MQTT.
  /// Prefer providing [caCertPem] instead.
  final bool allowBadCerts;

  /// PEM text of the device CA cert (recommended). If provided, we'll use a
  /// custom SecurityContext trusting only this PEM.
  final String? caCertPem;

  /// MQTT port on the printer (default 8883 for TLS)
  final int mqttPort;

  /// FTP port (21). Use explicit TLS (FTPES) with [useFtps] if available.
  final int ftpPort;

  /// Use explicit TLS for FTP (aka FTPES). Falls back to plain FTP if the
  /// server doesn't support it.
  final bool useFtps;

  const BambuLanConfig({
    required this.printerIp,
    required this.accessCode,
    this.serial,
    this.allowBadCerts = true,
    this.caCertPem,
    this.mqttPort = 8883,
    //this.ftpPort = 21,
    //this.useFtps = false,
    this.ftpPort = 990,
    this.useFtps = true,
  });
}

/// Simple directory entry abstraction for FTP results.
class FtpEntry {
  final String name;
  final bool isDir;
  final int? size;
  final DateTime? modified;
  final String path;

  const FtpEntry({
    required this.name,
    required this.isDir,
    required this.path,
    this.size,
    this.modified,
  });
}

/// Report event wrapper for MQTT frames.
class BambuReportEvent {
  final String topic;
  final Map<String, dynamic> json;
  final String? type; // high-level message type or state
  final String? firmwareVersion;
  final BambuPrintStatus?
  printStatus; // parsed metrics if this is a print report
  const BambuReportEvent({
    required this.topic,
    required this.json,
    this.type,
    this.firmwareVersion,
    this.printStatus,
  });
}

/// A hardware-management fault reported by the printer.
///
/// Bambu's report protocol carries HMS codes as two 32-bit values. Retain
/// them even when a firmware version does not include a human-readable text.
class BambuHmsEvent {
  final int code;
  final int attr;
  final String? message;

  const BambuHmsEvent({required this.code, required this.attr, this.message});

  // MQTT attr identifies the component; code contains the level and condition.
  // Bambu Studio's DevHMSItem::get_long_error_code uses this ordering.
  String get catalogCode =>
      '${attr.toRadixString(16).padLeft(8, '0')}'
              '${code.toRadixString(16).padLeft(8, '0')}'
          .toUpperCase();

  String get displayCode =>
      '${(attr >> 16).toRadixString(16).padLeft(4, '0').toUpperCase()}-'
      '${(attr & 0xffff).toRadixString(16).padLeft(4, '0').toUpperCase()}-'
      '${(code >> 16).toRadixString(16).padLeft(4, '0').toUpperCase()}-'
      '${(code & 0xffff).toRadixString(16).padLeft(4, '0').toUpperCase()}';

  /// Some HMS codes are maintenance notices rather than printer faults.
  /// Bambu does not currently include a text message for this code in MQTT.
  bool get isInformational =>
      catalogCode == '0500010000030004' || code >> 16 == 4;

  bool get isError => !isInformational && (code >> 16 == 1 || code >> 16 == 2);

  String? get knownMessage {
    if (message?.trim().isNotEmpty == true) return message!.trim();
    if (catalogCode == '0500010000030004') {
      return 'MicroSD card is full. Free space on the card or replace it.';
    }
    return bambuHmsDescriptions[catalogCode];
  }
}

/// A physical AMS tray or external spool reported by the printer.
class BambuFilamentTray {
  final int trayIndex;
  final int? amsIndex;
  final int? slotIndex;
  final bool isExternal;
  final String? name;
  final String? type;
  final String? color;
  final int? remainingPercent;

  const BambuFilamentTray({
    required this.trayIndex,
    this.amsIndex,
    this.slotIndex,
    this.isExternal = false,
    this.name,
    this.type,
    this.color,
    this.remainingPercent,
  });

  String get label {
    if (isExternal) return 'External spool';
    if (amsIndex == null || slotIndex == null) return 'AMS tray $trayIndex';
    return 'AMS ${amsIndex! + 1} / Slot ${slotIndex! + 1}';
  }
}

class BambuPrintStatus {
  final String gcodeState; // e.g. RUNNING, IDLE, FINISH
  final int? percent; // mc_percent 0..100
  final int? remainingMinutes; // mc_remaining_time (minutes)
  final String? gcodeFile; // gcode_file
  final int? layer; // layer_num
  final int? totalLayers; // total_layer_num
  final double? bedTemp; // bed_temper
  final double? bedTarget; // bed_target_temper
  final double? nozzleTemp; // nozzle_temper
  final double? nozzleTarget; // nozzle_target_temper
  final double? chamberTemp; // chamber_temper
  final String? nozzleType; // nozzle_type
  final String? nozzleDiameter; // nozzle_diameter
  final int? speedLevel; // spd_lvl
  final int? speedMag; // spd_mag
  final String? subtaskName; // subtask_name
  final String? taskId; // task_id
  final String? jobId; // job_id
  final String? wifiSignal; // wifi_signal, e.g. -48dBm
  final int? stage; // stg_cur / mc_print_stage
  final int? printError; // print_error, 0 means no printer error
  final String? printerMessage; // printer-supplied rejection/failure reason
  final List<BambuHmsEvent> hms;
  final bool hasHmsReport;
  final List<BambuFilamentTray> filamentTrays;
  final bool hasFilamentReport;
  final int? activeTrayIndex; // ams.tray_now; 254 is external spool
  final int? targetTrayIndex; // ams.tray_tar

  const BambuPrintStatus({
    required this.gcodeState,
    this.percent,
    this.remainingMinutes,
    this.gcodeFile,
    this.layer,
    this.totalLayers,
    this.bedTemp,
    this.bedTarget,
    this.nozzleTemp,
    this.nozzleTarget,
    this.chamberTemp,
    this.nozzleType,
    this.nozzleDiameter,
    this.speedLevel,
    this.speedMag,
    this.subtaskName,
    this.taskId,
    this.jobId,
    this.wifiSignal,
    this.stage,
    this.printError,
    this.printerMessage,
    this.hms = const [],
    this.hasHmsReport = false,
    this.filamentTrays = const [],
    this.hasFilamentReport = false,
    this.activeTrayIndex,
    this.targetTrayIndex,
  });

  bool get hasPrinterFault =>
      hms.isNotEmpty || (printError != null && printError != 0);

  BambuFilamentTray? get activeFilament {
    final target = activeTrayIndex;
    if (target == null) return null;
    for (final tray in filamentTrays) {
      if (tray.trayIndex == target || (target == 254 && tray.isExternal)) {
        return tray;
      }
    }
    return null;
  }
}

// =============================
// High-Level Orchestrating Class
// =============================

class BambuLan {
  final BambuLanConfig config;
  late final BambuMqtt mqtt = BambuMqtt(config);
  //late final BambuFtp ftp = BambuFtp(config);

  Stream<BambuReportEvent> get reportStream => mqtt.reportStream;

  BambuLan({required this.config});

  Future<void> connect() async {
    await mqtt.connect();
  }

  Future<void> dispose() async {
    await mqtt.dispose();
    //await ftp.dispose();
  }
}
