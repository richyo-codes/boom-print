class ThreeMfProjectInfo {
  final String? projectName;
  final String? printerProfile;
  final List<ThreeMfPlateInfo> plates;
  final List<ThreeMfFilamentInfo> filaments;
  final Map<String, String> fields;
  final List<String> warnings;
  final List<String> notes;

  const ThreeMfProjectInfo({
    required this.projectName,
    required this.printerProfile,
    required this.plates,
    required this.filaments,
    required this.fields,
    required this.warnings,
    required this.notes,
  });

  bool get hasUsefulMetadata =>
      projectName != null ||
      printerProfile != null ||
      plates.isNotEmpty ||
      filaments.isNotEmpty ||
      warnings.isNotEmpty ||
      notes.isNotEmpty;

  List<String> get filamentHints {
    final out = <String>[];
    for (final filament in filaments) {
      final summary = filament.summary;
      if (summary.isNotEmpty && !out.contains(summary)) {
        out.add(summary);
      }
    }
    return out;
  }

  List<ThreeMfFilamentInfo> get orderedFilaments {
    final copy = filaments.toList(growable: false);
    copy.sort((a, b) {
      final aSlot = a.slot ?? 1 << 30;
      final bSlot = b.slot ?? 1 << 30;
      final bySlot = aSlot.compareTo(bSlot);
      if (bySlot != 0) return bySlot;
      return a.summary.compareTo(b.summary);
    });
    return copy;
  }

  List<String> get plateSummaries {
    return plates
        .map((plate) => plate.summary)
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  List<String> get nozzleHints {
    final out = <String>[];
    for (final filament in filaments) {
      final nozzle = filament.nozzleDiameter?.trim() ?? '';
      if (nozzle.isNotEmpty && !out.contains(nozzle)) {
        out.add(nozzle);
      }
    }
    return out;
  }

  String? get nozzleSummary {
    final hints = nozzleHints;
    if (hints.isEmpty) return null;
    return hints.join(', ');
  }

  String? compatibilityWarningFor(String selectedLabel) {
    final label = selectedLabel.trim().toLowerCase();
    if (label.isEmpty || filaments.isEmpty) return null;

    final expectedTokens = <String>{
      for (final filament in filaments) ...filament.compatibilityTokens,
    }.toList();
    if (expectedTokens.isEmpty) return null;

    for (final token in expectedTokens) {
      if (label.contains(token)) {
        return null;
      }
    }

    return 'Project metadata suggests ${filamentHints.join(', ')} '
        'but the selected filament is "$selectedLabel".';
  }
}

class ThreeMfPlateInfo {
  final int index;
  final String? name;
  final String? gcodePath;
  final Map<String, String> fields;
  final List<String> filamentHints;

  const ThreeMfPlateInfo({
    required this.index,
    required this.name,
    required this.gcodePath,
    required this.fields,
    required this.filamentHints,
  });

  String get summary {
    final parts = <String>[
      'Plate $index',
      if (name != null && name!.trim().isNotEmpty) name!.trim(),
      if (filamentHints.isNotEmpty) filamentHints.join(', '),
    ];
    return parts.join(' • ');
  }
}

class ThreeMfFilamentInfo {
  final int? slot;
  final String? label;
  final String? material;
  final String? profile;
  final String? settingsId;
  final String? brand;
  final String? color;
  final String? nozzleDiameter;
  final Map<String, String> fields;

  const ThreeMfFilamentInfo({
    required this.slot,
    required this.label,
    required this.material,
    required this.profile,
    required this.settingsId,
    required this.brand,
    required this.color,
    required this.nozzleDiameter,
    required this.fields,
  });

  String get summary {
    final parts = <String>[
      if (slot != null) 'Slot $slot',
      if (label != null && label!.trim().isNotEmpty) label!.trim(),
      if (material != null && material!.trim().isNotEmpty) material!.trim(),
      if (profile != null && profile!.trim().isNotEmpty) profile!.trim(),
      if (settingsId != null && settingsId!.trim().isNotEmpty)
        settingsId!.trim(),
      if (brand != null && brand!.trim().isNotEmpty) brand!.trim(),
      if (color != null && color!.trim().isNotEmpty) color!.trim(),
      if (nozzleDiameter != null && nozzleDiameter!.trim().isNotEmpty)
        '${nozzleDiameter!.trim()} mm nozzle',
    ];
    return parts.join(' • ');
  }

  List<String> get compatibilityTokens {
    final out = <String>[];
    void addToken(String? value) {
      final token = _normalizeCompatibilityToken(value);
      if (token.isNotEmpty && !out.contains(token)) {
        out.add(token);
      }
    }

    addToken(label);
    addToken(material);
    addToken(profile);
    addToken(settingsId);
    addToken(brand);
    addToken(color);
    return out;
  }
}

String _normalizeCompatibilityToken(String? value) {
  final token = value?.trim().toLowerCase() ?? '';
  if (token.isEmpty) return '';
  final cleaned = token.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  if (cleaned.isEmpty) return '';
  final words = cleaned.split(RegExp(r'\s+'));
  if (words.isEmpty) return '';
  return words.join(' ');
}
