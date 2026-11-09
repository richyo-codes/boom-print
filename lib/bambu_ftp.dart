// // =========
// // FTP Client
// // =========

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:intl/intl.dart';
import 'package:boomprint/bambu_lan.dart';
import 'package:boomprint/log_redaction.dart';

class BambuFtp {
  final BambuLanConfig config;
  FTPConnect? _ftp; // lazily connected

  BambuFtp(this.config, {FTPConnect? client}) {
    _ftp = client;
  }

  Future<FTPConnect> _get() async {
    if (_ftp != null) return _ftp!;

    // Use FTPS by default (implicit TLS on 990 per OpenBambu docs).
    final useFtps = config.useFtps;
    SecurityType securityType = useFtps ? SecurityType.ftps : SecurityType.ftp;

    final logger = Logger(isEnabled: false);

    FTPConnect ftp;
    if (useFtps) {
      try {
        ftp = FTPConnect.withBackend(
          CurlFTPBackend(
            host: config.printerIp,
            port: config.ftpPort,
            securityType: securityType,
            verifyCertificate: false,
            secureDataChannel: true,
          ),
          user: 'bblp',
          pass: config.accessCode,
        );
      } catch (e) {
        stderr.writeln(
          redactLogText(
            'Curl FTP backend unavailable, falling back to socket backend: $e',
            secrets: [config.accessCode],
          ),
        );
        ftp = FTPConnect(
          config.printerIp,
          user: 'bblp',
          pass: config.accessCode,
          port: useFtps ? config.ftpPort : 21,
          securityType: securityType,
          showLog: false,
          logger: logger,
          timeout: const Duration(seconds: 15).inSeconds,
        );
      }
    } else {
      ftp = FTPConnect(
        config.printerIp,
        user: 'bblp',
        pass: config.accessCode,
        port: useFtps ? config.ftpPort : 21,
        securityType: securityType,
        showLog: false,
        logger: logger,
        timeout: const Duration(seconds: 15).inSeconds,
      );
    }
    // Prefer classic LIST for compatibility (vsftpd often lacks MLSD)
    ftp.listCommand = ListCommand.list;
    ftp.transferMode = TransferMode.passive;
    await ftp.connect().timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        throw TimeoutException(
          'FTP connect timeout (12s)',
          const Duration(seconds: 12),
        );
      },
    );
    _ftp = ftp;
    return ftp;
  }

  Future<void> dispose() async {
    try {
      await _ftp?.disconnect();
    } catch (_) {}
    _ftp = null;
  }

  Future<List<FtpEntry>> list(
    String path, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final target = path.isEmpty ? '/' : path;
    final ftp = await _get();
    try {
      final previousDir = await ftp.currentDirectory();
      try {
        final changed = await ftp.changeDirectory(target);
        if (!changed) {
          throw FTPConnectException('FTP CWD failed for $target');
        }
        final rawEntries = await ftp.listDirectoryContent().timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException('FTP LIST timed out', timeout);
          },
        );
        final entries = rawEntries
            .where((e) => e.name.isNotEmpty)
            .map(
              (e) => FtpEntry(
                name: e.name,
                isDir: e.type == FTPEntryType.dir,
                size: e.size,
                modified: e.modifyTime,
                path: target.endsWith('/')
                    ? '$target${e.name}'
                    : '$target/${e.name}',
              ),
            )
            .toList();
        if (entries.isEmpty) {
          throw FTPConnectException('FTP LIST returned no data');
        }
        return entries;
      } finally {
        try {
          await ftp.changeDirectory(previousDir);
        } catch (_) {}
      }
    } on TimeoutException {
      await dispose();
      throw TimeoutException(
        'FTP list timed out after ${timeout.inSeconds}s',
        timeout,
      );
    }
  }

  Future<_FtpReply> _sendCommand(
    SecureSocket socket,
    _FtpControlReader reader,
    String command,
    Duration timeout,
  ) async {
    socket.add(utf8.encode('$command\r\n'));
    await socket.flush();
    return reader.readResponse(timeout);
  }

  Future<String> _readDataSocket(SecureSocket socket, Duration timeout) async {
    final buffer = BytesBuilder();
    final completer = Completer<String>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (chunk) => buffer.add(chunk),
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(utf8.decode(buffer.takeBytes()));
        }
      },
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        sub.cancel();
        throw TimeoutException('FTP data transfer timed out', timeout);
      },
    );
  }

  _PasvEndpoint _parsePasvEndpoint(
    String message, {
    required String fallbackHost,
  }) {
    final match = RegExp(r'\((\d+,\d+,\d+,\d+,\d+,\d+)\)').firstMatch(message);
    if (match == null) {
      throw FTPConnectException('Failed to parse PASV response: $message');
    }
    final parts = match.group(1)!.split(',').map(int.parse).toList();
    final host = '${parts[0]}.${parts[1]}.${parts[2]}.${parts[3]}';
    final port = (parts[4] << 8) + parts[5];
    final resolvedHost = host == '0.0.0.0' ? fallbackHost : host;
    return _PasvEndpoint(resolvedHost, port);
  }

  Future<void> ensureDir(String path) async {
    final ftp = await _get();
    await ftp.createFolderIfNotExist(path);
  }

  Future<bool> downloadFile(String remotePath, File localFile) async {
    final ftp = await _get();
    return ftp.downloadFile(remotePath, localFile);
  }

  /// Upload a local file (by path) to a remote full path (including filename).
  Future<void> upload({
    required String localPath,
    required String remotePath,
  }) async {
    final ftp = await _get();
    final file = File(localPath);
    if (!await file.exists()) {
      throw ArgumentError('Local file does not exist: $localPath');
    }
    final remoteDir = remotePath.substring(0, remotePath.lastIndexOf('/'));
    await ftp.createFolderIfNotExist(remoteDir);
    await ftp.changeDirectory(remoteDir);
    await ftp.uploadFileWithRetry(file, pRetryCount: 2);
  }

  static List<FtpEntry> parseLsResponse(
    String message, {
    String currentPath = '/',
  }) {
    final entries = <FtpEntry>[];
    for (final rawLine in message.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (RegExp(r'^\d{3}').hasMatch(line)) continue; // skip reply codes
      final parsed = _parseUnixListLine(line, currentPath);
      if (parsed != null) entries.add(parsed);
    }
    return entries;
  }

  static FtpEntry? _parseUnixListLine(String line, String currentPath) {
    final re = RegExp(
      r'^([\-ld])([rwx\-]{9})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+'
      r'([A-Za-z]{3}\s+\d{1,2}\s+(?:\d{2}:\d{2}|\d{4}))\s+(.+)$',
    );
    final m = re.firstMatch(line);
    if (m == null) return null;
    final typeChar = m.group(1);
    final size = int.tryParse(m.group(3) ?? '');
    final dateStr = m.group(4)!;
    final name = m.group(5) ?? '';

    DateTime? modified;
    try {
      final now = DateTime.now();
      final withYear = dateStr.contains(':') ? '$dateStr ${now.year}' : dateStr;
      final fmt = dateStr.contains(':') ? 'MMM d HH:mm yyyy' : 'MMM d yyyy';
      modified = DateFormat(fmt, 'en_US').parse(withYear);
    } catch (_) {}

    String buildPath(String base, String name) {
      if (base.isEmpty || base == '/') return '/$name';
      return base.endsWith('/') ? '$base$name' : '$base/$name';
    }

    return FtpEntry(
      name: name,
      isDir: typeChar == 'd',
      path: buildPath(currentPath, name),
      size: size,
      modified: modified,
    );
  }
}

class _FtpReply {
  final int code;
  final String message;

  const _FtpReply(this.code, this.message);
}

class _PasvEndpoint {
  final String host;
  final int port;

  const _PasvEndpoint(this.host, this.port);
}

class _FtpControlReader {
  final StreamIterator<String> _lines;

  _FtpControlReader(SecureSocket socket)
    : _lines = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  Future<_FtpReply> readResponse(Duration timeout) async {
    final lines = <String>[];
    String? firstLine;
    String? code;
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      if (!await _lines.moveNext().timeout(remaining)) {
        break;
      }
      final line = _lines.current;
      lines.add(line);
      if (line.trim().isEmpty) continue;

      if (firstLine == null) {
        firstLine = line;
        if (firstLine.length >= 4 && firstLine[3] == '-') {
          code = firstLine.substring(0, 3);
          continue;
        }
      }

      if (code != null && line.startsWith('$code ')) {
        return _FtpReply(int.tryParse(code) ?? 0, lines.join('\n'));
      }

      if (RegExp(r'^\d{3} ').hasMatch(line)) {
        final parsed = int.tryParse(line.substring(0, 3)) ?? 0;
        return _FtpReply(parsed, lines.join('\n'));
      }
    }

    throw TimeoutException('FTP response timed out', timeout);
  }
}
