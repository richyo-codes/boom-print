import 'package:flutter_test/flutter_test.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:boomprint/bambu_ftp.dart';
import 'package:boomprint/bambu_lan.dart';

class _FakeFtpConnect extends FTPConnect {
  final List<FTPEntry> entries;
  final List<String?> changedDirectories = <String?>[];

  _FakeFtpConnect(String response)
    : entries = response
          .trim()
          .split('\n')
          .map((line) => FTPEntry.parse(line, ListCommand.list))
          .toList(),
      super('fake');

  @override
  Future<String> currentDirectory() async => '/';

  @override
  Future<bool> changeDirectory(String? directory) async {
    changedDirectories.add(directory);
    return true;
  }

  @override
  Future<List<FTPEntry>> listDirectoryContent() async => entries;

  @override
  Future<bool> disconnect() async => true;
}

void main() {
  const sampleLs = '''
-rw-r--r--    1 1000     1000       956162 Aug 06 01:30 3.5inch_Dell_harddiver_bracket_storage_.gcode.3mf
-rw-r--r--    1 1000     1000       416806 Jul 19 03:45 3M_Command_Strip_-_Honeycomb_Storage_Wall_Mount.gcode.3mf
''';

  test('parseLsResponse parses unix ls lines', () {
    final entries = BambuFtp.parseLsResponse(sampleLs, currentPath: '/');
    expect(entries.length, 2);
    expect(entries.first.name, startsWith('3.5inch_Dell'));
    expect(entries.first.isDir, isFalse);
    expect(
      entries.first.path,
      '/3.5inch_Dell_harddiver_bracket_storage_.gcode.3mf',
    );
    expect(entries.first.size, 956162);
    expect(entries.first.modified, isNotNull);
  });

  test('list retains server metadata from directory entries', () async {
    final fake = _FakeFtpConnect(sampleLs);
    final cfg = BambuLanConfig(
      printerIp: '0.0.0.0',
      accessCode: 'x',
      serial: 's',
    );
    final client = BambuFtp(cfg, client: fake);

    final entries = await client.list('/');
    expect(entries.length, 2);
    expect(fake.changedDirectories, ['/', '/']);
    expect(entries.first.modified, isNotNull);
    expect(entries.first.size, 956162);
  });
}
