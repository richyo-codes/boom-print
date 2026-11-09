import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'three_mf_models.dart';

class ThreeMfParser {
  const ThreeMfParser();

  Future<ThreeMfProjectInfo?> parseBytes(Uint8List bytes) async {
    return parseArchive(_decodeArchive(bytes));
  }

  Future<ThreeMfProjectInfo?> parseString(String text) async {
    return parseBytes(Uint8List.fromList(utf8.encode(text)));
  }

  ThreeMfProjectInfo? parseArchive(Archive? archive) {
    if (archive == null) return null;

    final projectFields = <String, String>{};
    final plateBuilders = <int, _PlateBuilder>{};
    final filamentBuilders = <int, _FilamentBuilder>{};
    final warnings = <String>[];
    final notes = <String>[];

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.trim();
      if (name.isEmpty) continue;

      final lowerName = name.toLowerCase();
      final text = _decodeText(file.content as List<int>);
      if (text.trim().isEmpty) continue;

      final plateIndex = _plateIndexFromPath(lowerName);
      if (plateIndex != null) {
        final plate = plateBuilders.putIfAbsent(
          plateIndex,
          () => _PlateBuilder(index: plateIndex),
        );
        plate.gcodePath ??= name;
        _parseText(
          text,
          onPair: (key, value) => _consumePair(
            key: key,
            value: value,
            plate: plate,
            projectFields: projectFields,
            filamentBuilders: filamentBuilders,
          ),
        );
        continue;
      }

      _parseText(
        text,
        onPair: (key, value) => _consumePair(
          key: key,
          value: value,
          projectFields: projectFields,
          filamentBuilders: filamentBuilders,
        ),
      );

      if (lowerName.endsWith('.gcode')) {
        notes.add('Found embedded G-code preview: $name');
      }
    }

    final plates =
        plateBuilders.values.map((builder) => builder.build()).toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    final filaments = filamentBuilders.values
        .map((builder) => builder.build())
        .where((f) => f.summary.isNotEmpty)
        .toList();

    final projectName = _firstNonEmpty([
      projectFields['project_name'],
      projectFields['title'],
      projectFields['name'],
    ]);
    final printerProfile = _firstNonEmpty([
      projectFields['printer_profile'],
      projectFields['printer_model'],
      projectFields['profile_name'],
      projectFields['printer'],
    ]);

    if (plates.isEmpty && filaments.isEmpty && projectFields.isEmpty) {
      return null;
    }

    if (plates.isEmpty) {
      warnings.add('No plate-specific G-code was found in the 3MF archive.');
    }
    if (filaments.isEmpty) {
      warnings.add(
        'No filament metadata was found in the 3MF archive; compatibility is inferred.',
      );
    }

    return ThreeMfProjectInfo(
      projectName: projectName,
      printerProfile: printerProfile,
      plates: plates,
      filaments: filaments,
      fields: projectFields,
      warnings: warnings,
      notes: notes,
    );
  }

  Archive? _decodeArchive(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  void _parseText(
    String text, {
    required void Function(String key, String value) onPair,
  }) {
    if (_looksLikeJson(text)) {
      try {
        _emitJsonPairs(jsonDecode(text), onPair: onPair);
        return;
      } on FormatException {
        // Fall through to XML and line scanning for malformed JSON.
      }
    }

    if (_looksLikeXml(text)) {
      try {
        final document = XmlDocument.parse(text);
        for (final element in document.descendants.whereType<XmlElement>()) {
          final tag = element.name.local;
          final inner = element.innerText.trim();
          if (tag.toLowerCase() == 'metadata') {
            final name = element.getAttribute('name')?.trim() ?? '';
            if (name.isNotEmpty && inner.isNotEmpty) {
              onPair(name, inner);
            }
          }
          if (inner.isNotEmpty) {
            onPair(tag, inner);
          }
          final slotSuffix = _xmlSlotSuffix(element);
          for (final attr in element.attributes) {
            final key = slotSuffix == null
                ? '${tag}_${attr.name.local}'
                : '${tag}_${slotSuffix}_${attr.name.local}';
            onPair(key, attr.value);
          }
        }
        return;
      } catch (_) {
        // Fall back to line scanning below.
      }
    }

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final stripped = line.startsWith(';') ? line.substring(1).trim() : line;
      if (stripped.isEmpty) continue;
      final match = RegExp(
        r'^([A-Za-z0-9_.\-\[\] ]+?)\s*[:=]\s*(.+)$',
      ).firstMatch(stripped);
      if (match != null) {
        onPair(match.group(1)!.trim(), match.group(2)!.trim());
        continue;
      }

      if (stripped.startsWith('filament') ||
          stripped.startsWith('printer') ||
          stripped.startsWith('project') ||
          stripped.startsWith('plate')) {
        final kv = stripped.split(RegExp(r'\s+'));
        for (final token in kv) {
          final pair = token.split('=');
          if (pair.length == 2) {
            onPair(pair[0].trim(), pair[1].trim());
          }
        }
      }
    }
  }

  void _emitJsonPairs(
    Object? value, {
    required void Function(String key, String value) onPair,
    String keyPrefix = '',
  }) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) continue;
        final qualifiedKey = keyPrefix.isEmpty ? key : '${keyPrefix}_$key';
        _emitJsonPairs(entry.value, onPair: onPair, keyPrefix: qualifiedKey);
      }
      return;
    }
    if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _emitJsonPairs(
          value[index],
          onPair: onPair,
          keyPrefix: _indexedFilamentKey(keyPrefix, index),
        );
      }
      return;
    }
    if (keyPrefix.isEmpty || value == null || value is bool) return;
    onPair(keyPrefix, value.toString());
  }

  void _consumePair({
    required String key,
    required String value,
    required Map<String, String> projectFields,
    _PlateBuilder? plate,
    required Map<int, _FilamentBuilder> filamentBuilders,
  }) {
    final normalizedKey = _normalizeKey(key);
    final normalizedValue = value.trim();
    if (normalizedKey.isEmpty || normalizedValue.isEmpty) return;

    projectFields.putIfAbsent(normalizedKey, () => normalizedValue);

    final values = _splitFilamentValues(normalizedKey, normalizedValue);
    if (values.length > 1) {
      for (var index = 0; index < values.length; index++) {
        _consumeSinglePair(
          key: _indexedFilamentKey(normalizedKey, index),
          value: values[index],
          plate: plate,
          filamentBuilders: filamentBuilders,
        );
      }
      return;
    }
    _consumeSinglePair(
      key: normalizedKey,
      value: values.single,
      plate: plate,
      filamentBuilders: filamentBuilders,
    );
  }

  void _consumeSinglePair({
    required String key,
    required String value,
    _PlateBuilder? plate,
    required Map<int, _FilamentBuilder> filamentBuilders,
  }) {
    final normalizedKey = _normalizeKey(key);
    final normalizedValue = _stripWrappingQuotes(value);
    if (normalizedKey.isEmpty || normalizedValue.isEmpty) return;

    final plateBuilder = plate;
    if (plateBuilder != null) {
      plateBuilder.consume(normalizedKey, normalizedValue);
    }

    final slotIndex = _slotIndexFromKey(normalizedKey, normalizedValue);
    final filamentBuilder = _maybeGetFilamentBuilder(
      filamentBuilders,
      slotIndex,
      normalizedKey,
    );
    if (filamentBuilder != null) {
      filamentBuilder.consume(normalizedKey, normalizedValue);
    }
  }

  _FilamentBuilder? _maybeGetFilamentBuilder(
    Map<int, _FilamentBuilder> builders,
    int? slotIndex,
    String normalizedKey,
  ) {
    if (!_isFilamentRelevantKey(normalizedKey)) return null;
    final key = slotIndex ?? -1;
    return builders.putIfAbsent(key, () => _FilamentBuilder(slot: key));
  }

  bool _looksLikeXml(String text) {
    final trimmed = text.trimLeft();
    return trimmed.startsWith('<?xml') || trimmed.startsWith('<');
  }

  bool _looksLikeJson(String text) {
    final trimmed = text.trimLeft();
    return trimmed.startsWith('{') || trimmed.startsWith('[');
  }

  String _decodeText(List<int> content) {
    try {
      return utf8.decode(content);
    } catch (_) {
      return utf8.decode(content, allowMalformed: true);
    }
  }

  int? _plateIndexFromPath(String lowerName) {
    final match = RegExp(r'plate[_-]?(\d+)\.gcode').firstMatch(lowerName);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  int? _slotIndexFromKey(String key, String value) {
    final numericValue = int.tryParse(value.trim());
    final slotKey = RegExp(r'(?:filament|tray|slot|ams)(?:_|-)?(\d+)');
    final keyMatch = slotKey.firstMatch(key);
    if (keyMatch != null) {
      return int.tryParse(keyMatch.group(1)!);
    }
    final valueMatch = slotKey.firstMatch(value.toLowerCase());
    if (valueMatch != null) {
      return int.tryParse(valueMatch.group(1)!);
    }
    if ((key.contains('slot') || key.contains('tray') || key.contains('ams')) &&
        numericValue != null) {
      return numericValue;
    }
    return null;
  }

  List<String> _splitFilamentValues(String key, String value) {
    if (!_isFilamentCollectionKey(key) || !value.contains(';')) {
      return <String>[_stripWrappingQuotes(value)];
    }
    final values = value
        .split(';')
        .map(_stripWrappingQuotes)
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    return values.isEmpty ? <String>[_stripWrappingQuotes(value)] : values;
  }

  String? _xmlSlotSuffix(XmlElement element) {
    final tag = element.name.local.toLowerCase();
    if (tag != 'filament') return null;
    for (final attr in element.attributes) {
      final name = attr.name.local.toLowerCase();
      if (name == 'slot' || name == 'tray' || name == 'ams') {
        final suffix = _normalizeKey(attr.value);
        if (suffix.isNotEmpty) {
          return suffix;
        }
      }
    }
    return null;
  }
}

class _PlateBuilder {
  final int index;
  String? name;
  String? gcodePath;
  final Map<String, String> fields = <String, String>{};
  final List<String> filamentHints = <String>[];

  _PlateBuilder({required this.index});

  void consume(String key, String value) {
    fields.putIfAbsent(key, () => value);
    if (_isPlateNameKey(key) && name == null) {
      name = value;
    }
    if (_isFilamentHintKey(key)) {
      final hint = _hintFromKeyValue(key, value);
      if (hint.isNotEmpty && !filamentHints.contains(hint)) {
        filamentHints.add(hint);
      }
    }
  }

  ThreeMfPlateInfo build() {
    return ThreeMfPlateInfo(
      index: index,
      name: name,
      gcodePath: gcodePath,
      fields: Map<String, String>.unmodifiable(fields),
      filamentHints: List<String>.unmodifiable(filamentHints),
    );
  }
}

class _FilamentBuilder {
  final int slot;
  String? label;
  String? material;
  String? profile;
  String? settingsId;
  String? brand;
  String? color;
  String? nozzleDiameter;
  final Map<String, String> fields = <String, String>{};

  _FilamentBuilder({required this.slot});

  void consume(String key, String value) {
    fields.putIfAbsent(key, () => value);
    if (_isLabelKey(key) && label == null) {
      label = value;
    } else if (_isMaterialKey(key) && material == null) {
      material = value;
    } else if (_isProfileKey(key) && profile == null) {
      profile = value;
    } else if (_isFilamentSettingsKey(key) && settingsId == null) {
      settingsId = value;
    } else if (_isBrandKey(key) && brand == null) {
      brand = value;
    } else if (_isColorKey(key) && color == null) {
      color = value;
    } else if (_isNozzleDiameterKey(key) &&
        _isNozzleDiameterValue(value) &&
        nozzleDiameter == null) {
      nozzleDiameter = value;
    }
  }

  ThreeMfFilamentInfo build() {
    return ThreeMfFilamentInfo(
      slot: slot < 0 ? null : slot,
      label: label,
      material: material,
      profile: profile,
      settingsId: settingsId,
      brand: brand,
      color: color,
      nozzleDiameter: nozzleDiameter,
      fields: Map<String, String>.unmodifiable(fields),
    );
  }
}

bool _isPlateNameKey(String key) {
  return key.contains('plate_name') || key == 'plate' || key.endsWith('_plate');
}

bool _isFilamentHintKey(String key) {
  return key.contains('filament') || key.contains('material');
}

bool _isFilamentRelevantKey(String key) {
  return _isFilamentHintKey(key) ||
      _isLabelKey(key) ||
      _isMaterialKey(key) ||
      _isProfileKey(key) ||
      _isFilamentSettingsKey(key) ||
      _isBrandKey(key) ||
      _isColorKey(key) ||
      _isNozzleDiameterKey(key);
}

bool _isLabelKey(String key) {
  return key.contains('filament_name') ||
      (key.contains('filament') && key.endsWith('_name')) ||
      key == 'filament' ||
      key == 'tray_id_name' ||
      key.endsWith('_label');
}

bool _isFilamentSettingsKey(String key) {
  return key.contains('filament') &&
      (key.contains('settings') ||
          key.contains('preset') ||
          key.endsWith('_id'));
}

bool _isMaterialKey(String key) {
  return key.contains('filament_type') ||
      (key.contains('filament') && key.endsWith('_type')) ||
      key == 'material' ||
      key.endsWith('_material') ||
      key == 'tray_type';
}

bool _isProfileKey(String key) {
  return key.contains('profile') || key.contains('filament_profile');
}

bool _isFilamentCollectionKey(String key) {
  return key.contains('filament') ||
      key.contains('tray') ||
      key.contains('ams');
}

bool _isBrandKey(String key) {
  return key.contains('brand') || key.contains('manufacturer');
}

bool _isColorKey(String key) {
  return key.contains('color') || key.contains('colour');
}

bool _isNozzleDiameterKey(String key) {
  return key.contains('nozzle') &&
      (key.contains('diameter') || key.contains('size'));
}

bool _isNozzleDiameterValue(String value) {
  return RegExp(
    r'^\s*\d+(?:\.\d+)?\s*(?:mm)?\s*$',
    caseSensitive: false,
  ).hasMatch(value);
}

String _stripWrappingQuotes(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 &&
      ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
          (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}

String _indexedFilamentKey(String key, int index) {
  final match = RegExp(r'^(filament)(_.+)$').firstMatch(key);
  if (match != null) {
    return '${match.group(1)}_${index}${match.group(2)}';
  }
  if (_isNozzleDiameterKey(key)) {
    return 'filament_${index}_$key';
  }
  return '${key}_$index';
}

String _hintFromKeyValue(String key, String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '';
  if (_isMaterialKey(key) || _isLabelKey(key) || _isProfileKey(key)) {
    return normalized;
  }
  return '';
}

String? _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    if (value == null) continue;
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String _normalizeKey(String key) {
  final normalized = key.toLowerCase().trim();
  if (normalized.isEmpty) return '';
  return normalized
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}
