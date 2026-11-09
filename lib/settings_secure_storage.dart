import 'dart:async';

import 'package:boomprint/log_redaction.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

class SecureSettingsSnapshot {
  final String? specialCode;
  final String? genericRtspPassword;
  final String? customUrl;

  const SecureSettingsSnapshot({
    this.specialCode,
    this.genericRtspPassword,
    this.customUrl,
  });
}

abstract final class SettingsSecureStorage {
  static const _specialCodeKey = 'boomprint.special_code';
  static const _genericRtspPasswordKey = 'boomprint.generic_rtsp_password';
  static const _customUrlKey = 'boomprint.custom_url';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  static const Duration _operationTimeout = Duration(seconds: 2);

  static bool get _isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.linux;

  static Future<SecureSettingsSnapshot> readSnapshot() async {
    if (!_isSupportedPlatform) {
      return const SecureSettingsSnapshot();
    }
    try {
      final values = await _storage.readAll().timeout(_operationTimeout);
      return SecureSettingsSnapshot(
        specialCode: values[_specialCodeKey],
        genericRtspPassword: values[_genericRtspPasswordKey],
        customUrl: values[_customUrlKey],
      );
    } catch (error, stackTrace) {
      debugPrint(
        redactLogText(
          'SettingsSecureStorage.readSnapshot failed; falling back to non-secure storage: '
          '$error',
        ),
      );
      debugPrintStack(stackTrace: stackTrace);
      return const SecureSettingsSnapshot();
    }
  }

  static Future<bool> writeSnapshot({
    required String specialCode,
    required String genericRtspPassword,
    required String customUrl,
  }) async {
    if (!_isSupportedPlatform) {
      return false;
    }
    try {
      await _writeString(_specialCodeKey, specialCode);
      await _writeString(_genericRtspPasswordKey, genericRtspPassword);
      await _writeString(_customUrlKey, customUrl);
      return true;
    } catch (error, stackTrace) {
      debugPrint(
        redactLogText(
          'SettingsSecureStorage.writeSnapshot failed; keeping plaintext fallback in app storage: '
          '$error',
          secrets: [specialCode, genericRtspPassword, customUrl],
        ),
      );
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  static Future<void> _writeString(String key, String value) async {
    if (value.isEmpty) {
      await _storage.delete(key: key).timeout(_operationTimeout);
      return;
    }
    await _storage.write(key: key, value: value).timeout(_operationTimeout);
  }
}
