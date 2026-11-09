import 'printer_url_formats.dart';

enum PrinterProfileKind { local, cloud }

enum PrinterUrlSource { builtIn, custom }

enum PrinterUrlRole { control, camera, fileTransfer }

final class PrinterUrlRecord {
  final String id;
  final String label;
  final String url;
  final PrinterUrlSource source;
  final PrinterUrlRole role;
  final bool isDefault;

  const PrinterUrlRecord({
    required this.id,
    required this.label,
    required this.url,
    required this.source,
    required this.role,
    this.isDefault = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'url': url,
    'source': source.name,
    'role': role.name,
    'isDefault': isDefault,
  };

  factory PrinterUrlRecord.fromJson(Map<String, dynamic> json) {
    return PrinterUrlRecord(
      id: (json['id'] ?? '') as String,
      label: (json['label'] ?? '') as String,
      url: (json['url'] ?? '') as String,
      source: PrinterUrlSource.values.firstWhere(
        (value) => value.name == (json['source'] ?? ''),
        orElse: () => PrinterUrlSource.custom,
      ),
      role: PrinterUrlRole.values.firstWhere(
        (value) => value.name == (json['role'] ?? ''),
        orElse: () => PrinterUrlRole.camera,
      ),
      isDefault: (json['isDefault'] ?? false) as bool,
    );
  }
}

final class PrinterProfile {
  final String id;
  final String displayName;
  final PrinterProfileKind kind;
  final PrinterUrlType printerType;
  final String printerIp;
  final String serialNumber;
  final String accessCode;
  final List<PrinterUrlRecord> urls;
  final String? selectedUrlId;

  const PrinterProfile({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.printerType,
    required this.printerIp,
    required this.serialNumber,
    required this.accessCode,
    required this.urls,
    this.selectedUrlId,
  });

  List<PrinterUrlRecord> get builtInUrls => urls
      .where((url) => url.source == PrinterUrlSource.builtIn)
      .toList(growable: false);

  List<PrinterUrlRecord> get customUrls => urls
      .where((url) => url.source == PrinterUrlSource.custom)
      .toList(growable: false);

  List<PrinterUrlRecord> get cameraUrls => urls
      .where((url) => url.role == PrinterUrlRole.camera)
      .toList(growable: false);

  PrinterUrlRecord? get selectedUrl {
    final id = selectedUrlId;
    if (id == null || id.isEmpty) {
      return urls.where((url) => url.isDefault).firstOrNull ?? urls.firstOrNull;
    }
    for (final url in urls) {
      if (url.id == id) {
        return url;
      }
    }
    return urls.where((url) => url.isDefault).firstOrNull ?? urls.firstOrNull;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'kind': kind.name,
    'printerType': printerType.storageKey,
    'printerIp': printerIp,
    'serialNumber': serialNumber,
    'accessCode': accessCode,
    'selectedUrlId': selectedUrlId,
    'urls': urls.map((url) => url.toJson()).toList(growable: false),
  };

  factory PrinterProfile.fromJson(Map<String, dynamic> json) {
    final rawUrls = (json['urls'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PrinterUrlRecord.fromJson)
        .toList(growable: false);
    return PrinterProfile(
      id: (json['id'] ?? '') as String,
      displayName: (json['displayName'] ?? '') as String,
      kind: PrinterProfileKind.values.firstWhere(
        (value) => value.name == (json['kind'] ?? ''),
        orElse: () => PrinterProfileKind.local,
      ),
      printerType: PrinterUrlTypeX.parse(json['printerType'] as String?),
      printerIp: (json['printerIp'] ?? '') as String,
      serialNumber: (json['serialNumber'] ?? '') as String,
      accessCode: (json['accessCode'] ?? '') as String,
      selectedUrlId: json['selectedUrlId'] as String?,
      urls: rawUrls,
    );
  }

  static PrinterProfile fromLocalPrinterFields({
    required String id,
    required String displayName,
    required PrinterUrlType printerType,
    required String printerIp,
    required String serialNumber,
    required String accessCode,
    String customUrl = '',
    int cameraStreamCount = 1,
    int selectedCameraIndex = 0,
    String genericRtspUsername = '',
    String genericRtspPassword = '',
    String genericRtspPath = '/stream',
    int genericRtspPort = 554,
    bool genericRtspSecure = false,
  }) {
    final urls = <PrinterUrlRecord>[
      PrinterUrlRecord(
        id: 'control',
        label: 'Main stream',
        url: _buildControlUrl(
          printerType: printerType,
          printerIp: printerIp,
          accessCode: accessCode,
          customUrl: customUrl,
          genericRtspUsername: genericRtspUsername,
          genericRtspPassword: genericRtspPassword,
          genericRtspPath: genericRtspPath,
          genericRtspPort: genericRtspPort,
          genericRtspSecure: genericRtspSecure,
        ),
        source: PrinterUrlSource.builtIn,
        role: PrinterUrlRole.control,
        isDefault: true,
      ),
    ];

    if (printerType.isBambuFamily) {
      final count = cameraStreamCount < printerType.defaultCameraCount
          ? printerType.defaultCameraCount
          : cameraStreamCount;
      for (var i = 0; i < count; i++) {
        final cameraNumber = i + 1;
        urls.add(
          PrinterUrlRecord(
            id: 'camera-$cameraNumber',
            label: count == 1 ? 'Camera' : 'Camera $cameraNumber',
            url:
                'rtsps://bblp:$accessCode@$printerIp:322/streaming/live/$cameraNumber',
            source: PrinterUrlSource.builtIn,
            role: PrinterUrlRole.camera,
          ),
        );
      }
    }

    if (customUrl.trim().isNotEmpty) {
      urls.add(
        PrinterUrlRecord(
          id: 'custom-control',
          label: 'Custom stream',
          url: customUrl.trim(),
          source: PrinterUrlSource.custom,
          role: PrinterUrlRole.control,
        ),
      );
    }

    return PrinterProfile(
      id: id,
      displayName: displayName,
      kind: PrinterProfileKind.local,
      printerType: printerType,
      printerIp: printerIp,
      serialNumber: serialNumber,
      accessCode: accessCode,
      urls: urls,
      selectedUrlId: 'control',
    );
  }

  static String _buildControlUrl({
    required PrinterUrlType printerType,
    required String printerIp,
    required String accessCode,
    required String customUrl,
    required String genericRtspUsername,
    required String genericRtspPassword,
    required String genericRtspPath,
    required int genericRtspPort,
    required bool genericRtspSecure,
  }) {
    return switch (printerType) {
      PrinterUrlType.custom => customUrl.trim(),
      PrinterUrlType.genericRtsp => _buildGenericRtspUrl(
        printerIp: printerIp,
        username: genericRtspUsername,
        password: genericRtspPassword,
        path: genericRtspPath,
        port: genericRtspPort,
        secure: genericRtspSecure,
      ),
      PrinterUrlType.bambuX1C ||
      PrinterUrlType.bambuP1S ||
      PrinterUrlType.bambuX2D ||
      PrinterUrlType.bambuH2C ||
      PrinterUrlType.bambuH2D ||
      PrinterUrlType.bambuH2S =>
        'rtsps://bblp:$accessCode@$printerIp:322/streaming/live/1',
    };
  }

  static String _buildGenericRtspUrl({
    required String printerIp,
    required String username,
    required String password,
    required String path,
    required int port,
    required bool secure,
  }) {
    final scheme = secure ? 'rtsps' : 'rtsp';
    final normalizedPath = path.trim().isEmpty
        ? '/stream'
        : (path.trim().startsWith('/') ? path.trim() : '/${path.trim()}');
    final user = username.trim();
    final userInfo = user.isEmpty
        ? ''
        : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}@';
    return '$scheme://$userInfo$printerIp:$port$normalizedPath';
  }
}

extension _FirstOrNullX<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
