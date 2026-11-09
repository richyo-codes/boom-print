import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_mf/three_mf.dart';

Uint8List _buildSampleThreeMf() {
  final archive = Archive();
  archive.addFile(
    ArchiveFile.string('Metadata/project_settings.config', '''
<?xml version="1.0" encoding="UTF-8"?>
<config>
  <project name="Calibration Cube" printer_profile="Bambu X1C" />
  <filament slot="1" filament_type="PETG" filament_name="Bambu PETG Basic" filament_color="FF0000FF" />
</config>
'''),
  );
  archive.addFile(
    ArchiveFile.string('Metadata/plate_1.gcode', '''
; plate_name = Top Plate
; filament_type = PETG
; filament_name = Bambu PETG Basic
; nozzle_diameter = 0.4
; nozzle_type = Standard
; printer_profile = Bambu X1C
G1 X0 Y0
'''),
  );
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded);
}

void main() {
  test('parses embedded 3MF metadata from package boundary', () async {
    final parser = ThreeMfParser();
    final info = await parser.parseBytes(_buildSampleThreeMf());

    expect(info, isNotNull);
    expect(info!.projectName, 'Calibration Cube');
    expect(info.printerProfile, 'Bambu X1C');
    expect(info.plates, hasLength(1));
    expect(info.plates.first.index, 1);
    expect(info.plates.first.filamentHints, isNotEmpty);
    expect(info.filamentHints, anyElement(contains('Bambu PETG Basic')));
    expect(info.nozzleHints, ['0.4']);
    expect(info.nozzleSummary, '0.4');
    expect(info.compatibilityWarningFor('AMS 1 / Slot 0 • PETG'), isNull);
    expect(info.compatibilityWarningFor('PLA'), isNotNull);
  });
}
