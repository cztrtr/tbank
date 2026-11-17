import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 安全存储里的键名。带版本号，方便以后换算法/迁移。
class SecretKeys {
  SecretKeys._();

  /// DeepSeek API Key。
  static const String dsApiKey = 'tbank.ds_api_key.v1';
}

/// 安全存储不可用/损坏时抛出，[code] 用于界面区分处理方式。
class SecretStoreException implements Exception {
  const SecretStoreException(this.code, this.message);

  /// unavailable：平台通道不存在或系统拒绝访问；
  /// corrupted：密文无法解开（常见于 Keystore 重置、备份恢复）。
  final String code;
  final String message;

  @override
  String toString() => 'SecretStoreException($code): $message';
}

/// 敏感字符串的统一读写接口。
///
/// 生产环境使用 [FlutterSecretStore]（Android Keystore / Windows DPAPI）；
/// 单元测试注入 [MemorySecretStore]，避免依赖平台通道。
abstract class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// 当前平台通道是否可用。默认 true，失败后由实现自行更新。
  bool get isAvailable;
}

/// 基于 flutter_secure_storage 的实现。
///
/// Android（v10+）默认使用 RSA-OAEP-SHA256 包装 AES 密钥 + AES-GCM 加密数据，
/// 私钥保存在 Android Keystore，磁盘上只有密文；Windows 使用 DPAPI
/// （CurrentUser 作用域），只有同一个 Windows 用户能解密。
class FlutterSecretStore implements SecretStore {
  FlutterSecretStore()
    : _storage = const FlutterSecureStorage(
        // 插件升级加密算法时保留一份加密备份，避免迁移中途崩溃丢数据。
        // 备份本身也是密文，不会把明文写到磁盘。
        aOptions: AndroidOptions(migrateWithBackup: true),
      );

  final FlutterSecureStorage _storage;
  bool _available = true;

  /// 单次读写超时：平台通道异常时不能让 App 启动一直卡住。
  static const Duration _timeout = Duration(seconds: 5);

  @override
  bool get isAvailable => _available;

  @override
  Future<String?> read(String key) async {
    try {
      final String? value = await _storage
          .read(key: key)
          .timeout(_timeout);
      _available = true;
      return value;
    } on MissingPluginException {
      _available = false;
      throw const SecretStoreException(
        'unavailable',
        '当前平台没有安全存储实现',
      );
    } on TimeoutException {
      _available = false;
      throw const SecretStoreException('unavailable', '读取安全存储超时');
    } on PlatformException catch (error) {
      _available = false;
      // 不同 ROM 的 code 不统一，这里不把原始 message 直接展示给用户，
      // 避免异常文本里夹带敏感内容；只保留错误码。
      throw SecretStoreException(
        _isCorrupted(error) ? 'corrupted' : 'unavailable',
        '读取安全存储失败（${error.code}）',
      );
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage
          .write(key: key, value: value)
          .timeout(_timeout);
      _available = true;
    } on MissingPluginException {
      _available = false;
      throw const SecretStoreException(
        'unavailable',
        '当前平台没有安全存储实现',
      );
    } on TimeoutException {
      _available = false;
      throw const SecretStoreException('unavailable', '写入安全存储超时');
    } on PlatformException catch (error) {
      _available = false;
      throw SecretStoreException(
        'unavailable',
        '写入安全存储失败（${error.code}）',
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key).timeout(_timeout);
      _available = true;
    } on MissingPluginException {
      _available = false;
      throw const SecretStoreException(
        'unavailable',
        '当前平台没有安全存储实现',
      );
    } on TimeoutException {
      _available = false;
      throw const SecretStoreException('unavailable', '删除安全存储超时');
    } on PlatformException catch (error) {
      _available = false;
      throw SecretStoreException(
        'unavailable',
        '删除安全存储失败（${error.code}）',
      );
    }
  }

  /// Keystore 被重置后，解密失败通常表现为 InvalidKeyException/KeyStore 相关错误。
  bool _isCorrupted(PlatformException error) {
    final String text = '${error.code} ${error.message ?? ''}'.toLowerCase();
    return text.contains('invalidkey') ||
        text.contains('keystore') ||
        text.contains('unwrap') ||
        text.contains('decrypt');
  }
}

/// 内存实现，仅供单元测试使用。
///
/// 不参与生产逻辑；[failRead]/[failWrite]/[failDelete] 用来模拟
/// Keystore 重置、磁盘只读、平台通道异常等情况。
class MemorySecretStore implements SecretStore {
  MemorySecretStore({
    Map<String, String>? initial,
    this.failRead = false,
    this.failWrite = false,
    this.failDelete = false,
  }) : _values = <String, String>{...?initial};

  final Map<String, String> _values;
  bool failRead;
  bool failWrite;
  bool failDelete;
  bool _available = true;

  @override
  bool get isAvailable => _available;

  @override
  Future<String?> read(String key) async {
    if (failRead) {
      _available = false;
      throw const SecretStoreException('unavailable', '模拟读取失败');
    }
    _available = true;
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) {
      _available = false;
      throw const SecretStoreException('unavailable', '模拟写入失败');
    }
    _available = true;
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) {
      _available = false;
      throw const SecretStoreException('unavailable', '模拟删除失败');
    }
    _available = true;
    _values.remove(key);
  }

  /// 测试断言用：直接看某个键当前的值。
  String? peek(String key) => _values[key];
}
