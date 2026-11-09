import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:three_mf/three_mf.dart';

Uint8List _encodeArchive(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded);
}

Future<ThreeMfProjectInfo?> _parseCase(Map<String, String> files) {
  return const ThreeMfParser().parseBytes(_encodeArchive(files));
}

void main() {
  group('ThreeMfParser', () {
    test('parses combined project metadata', () async {
      final info = await _parseCase({
        'Metadata/project_settings.config': '''
<?xml version="1.0" encoding="UTF-8"?>
<config>
  <project name="Calibration Cube" printer_profile="Bambu X1C" />
  <filament slot="1" filament_type="PETG" filament_name="Bambu PETG Basic" filament_color="FF0000FF" />
</config>
''',
        'Metadata/plate_1.gcode': '''
; plate_name = Top Plate
; filament_type = PETG
; filament_name = Bambu PETG Basic
; nozzle_diameter = 0.4
; printer_profile = Bambu X1C
G1 X0 Y0
''',
      });

      expect(info, isNotNull);
      expect(info!.projectName, 'Calibration Cube');
      expect(info.printerProfile, 'Bambu X1C');
      expect(info.plates, hasLength(1));
      expect(info.plates.first.index, 1);
      expect(info.plates.first.name, 'Top Plate');
      expect(info.filamentHints, anyElement(contains('Bambu PETG Basic')));
      expect(info.compatibilityWarningFor('AMS 1 / Slot 0 • PETG'), isNull);
      expect(info.compatibilityWarningFor('PLA'), isNotNull);
    });

    test('parses plate comments without project xml', () async {
      final info = await _parseCase({
        'Metadata/plate_1.gcode': '''
; plate_name = Draft Plate
; filament_type = PLA
; filament_name = Generic PLA
; nozzle_diameter = 0.4
G1 X10 Y10
''',
      });

      expect(info, isNotNull);
      expect(info!.projectName, isNull);
      expect(info.plates, hasLength(1));
      expect(info.plates.first.filamentHints, contains('PLA'));
      expect(info.warnings, isEmpty);
    });

    test('returns metadata warnings for incomplete archives', () async {
      final info = await _parseCase({
        'Metadata/project_settings.config': '''
<?xml version="1.0" encoding="UTF-8"?>
<config>
  <project name="Calibration Cube" printer_profile="Bambu X1C" />
  <filament slot="1" filament_type="PETG" filament_name="Bambu PETG Basic" />
</config>
''',
      });

      expect(info, isNotNull);
      expect(info!.projectName, 'Calibration Cube');
      expect(info.plates, isEmpty);
      expect(info.filaments, isNotEmpty);
      expect(
        info.warnings,
        contains('No plate-specific G-code was found in the 3MF archive.'),
      );
    });

    test('orders filaments by slot when available', () async {
      final info = await _parseCase({
        'Metadata/project_settings.config': '''
<?xml version="1.0" encoding="UTF-8"?>
<config>
  <filament slot="2" filament_type="PLA" filament_name="Second" />
  <filament slot="1" filament_type="PETG" filament_name="First" />
</config>
''',
      });

      expect(info, isNotNull);
      expect(info!.filaments, hasLength(2));
      expect(info.orderedFilaments.first.slot, 1);
      expect(info.orderedFilaments.last.slot, 2);
    });

    test('collects nozzle hints from filament metadata', () async {
      final info = await _parseCase({
        'Metadata/project_settings.config': '''
<?xml version="1.0" encoding="UTF-8"?>
<config>
  <filament slot="1" filament_type="PETG" filament_name="First" nozzle_diameter="0.4" />
  <filament slot="2" filament_type="PLA" filament_name="Second" nozzle_diameter="0.6" />
</config>
''',
      });

      expect(info, isNotNull);
      expect(info!.nozzleHints, containsAll(['0.4', '0.6']));
      expect(info.nozzleSummary, '0.4, 0.6');
    });

    test(
      'parses Bambu Studio JSON settings and multi-filament arrays',
      () async {
        final info = await _parseCase({
          'Metadata/project_settings.config': '''
{
  "project_name": "Four-color test",
  "printer_model": "Bambu Lab X1 Carbon",
  "filament_type": ["PETG", "PLA"],
  "filament_settings_id": [
    "Bambu PETG Basic @BBL X1C",
    "Bambu PLA Basic @BBL X1C"
  ],
  "filament_colour": ["#0055CC", "#FFFFFF"],
  "nozzle_diameter": ["0.4", "0.4"],
  "nozzle_type": "Standard"
}
''',
        });

        expect(info, isNotNull);
        expect(info!.projectName, 'Four-color test');
        expect(info.printerProfile, 'Bambu Lab X1 Carbon');
        expect(info.orderedFilaments, hasLength(2));
        expect(info.orderedFilaments.map((filament) => filament.slot), [0, 1]);
        expect(
          info.orderedFilaments.first.settingsId,
          'Bambu PETG Basic @BBL X1C',
        );
        expect(info.orderedFilaments.last.material, 'PLA');
        expect(info.nozzleHints, ['0.4']);
      },
    );

    test('parses standard 3MF metadata elements', () async {
      final info = await _parseCase({
        '3D/3dmodel.model': '''
<?xml version="1.0" encoding="UTF-8"?>
<model>
  <metadata name="Title">Bench bracket</metadata>
  <metadata name="Application">Bambu Studio</metadata>
</model>
''',
      });

      expect(info, isNotNull);
      expect(info!.projectName, 'Bench bracket');
    });
  });
}
