import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 插件清单失败时抛出，[message] 可直接展示给用户。
class PluginException implements Exception {
  const PluginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 插件声明的一种题型。
class PluginTypeInfo {
  const PluginTypeInfo({
    required this.id,
    required this.name,
    required this.description,
    this.schema,
    this.example,
  });

  /// 写入题库 JSON 的 type 标识。
  final String id;

  /// 给用户看的名称；插件没写时退回 id。
  final String name;

  /// 给 AI 的出题说明，也用于配置/展示。
  final String description;

  /// `pluginData` 的 JSON Schema；为空表示不校验。
  final Map<String, dynamic>? schema;

  /// 给 AI 看的 `pluginData` 示例。
  final Map<String, dynamic>? example;
}

/// 插件根目录下 `manifest.json` 的内容。
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.types,
    this.description = '',
    this.typeNames = const <String, String>{},
    this.typeDescriptions = const <String, String>{},
    this.typeSchemas = const <String, Map<String, dynamic>>{},
    this.typeExamples = const <String, Map<String, dynamic>>{},
    this.builtin = false,
  });

  final String id;
  final String name;
  final String version;
  final int apiVersion;

  /// 这个插件能处理的题目类型（对应题库 JSON 的 type）。
  final List<String> types;
  final String description;

  /// 题型 id → 展示名 / AI 出题说明；旧插件没有时为默认值。
  final Map<String, String> typeNames;
  final Map<String, String> typeDescriptions;

  /// 题型 id → `pluginData` 的 JSON Schema / 示例。
  final Map<String, Map<String, dynamic>> typeSchemas;
  final Map<String, Map<String, dynamic>> typeExamples;
  final bool builtin;

  /// 按 manifest 的 types 顺序生成题型信息。
  List<PluginTypeInfo> get typeInfos => types
      .map(
        (String id) => PluginTypeInfo(
          id: id,
          name: (typeNames[id] ?? '').trim().isEmpty ? id : typeNames[id]!,
          description: typeDescriptions[id] ?? '',
          schema: typeSchemas[id],
          example: typeExamples[id],
        ),
      )
      .toList();

  Map<String, dynamic>? schemaForType(String type) => typeSchemas[type];

  Map<String, dynamic>? exampleForType(String type) => typeExamples[type];

  factory PluginManifest.fromJson(
    Map<String, dynamic> json, {
    required bool builtin,
  }) {
    final String id = (json['id']?.toString() ?? '').trim();
    if (!PluginManager.isValidId(id)) {
      throw PluginException('插件 id 不合法：$id');
    }

    final String name = (json['name']?.toString() ?? '').trim();
    if (name.isEmpty) throw const PluginException('插件缺少 name');

    final String version = (json['version']?.toString() ?? '').trim();
    if (version.isEmpty) throw const PluginException('插件缺少 version');

    final dynamic rawApi = json['apiVersion'];
    final int apiVersion = rawApi is num ? rawApi.toInt() : 1;
    if (apiVersion > PluginManager.supportedApiVersion) {
      throw PluginException(
        '插件 API 版本 $apiVersion 高于 App 支持的 ${PluginManager.supportedApiVersion}',
      );
    }

    final dynamic rawTypes = json['types'];
    final List<String> types = rawTypes is List
        ? rawTypes
              .map((dynamic item) => item.toString().trim())
              .where((String item) => item.isNotEmpty)
              .toList()
        : <String>[];
    if (types.isEmpty) throw const PluginException('插件没有声明可处理的题目类型');

    Map<String, String> readStringMap(String key) {
      final dynamic raw = json[key];
      if (raw is! Map) return <String, String>{};
      final Set<String> declared = types.toSet();
      final Map<String, String> result = <String, String>{};
      raw.forEach((dynamic key, dynamic value) {
        final String typeId = key.toString();
        final String text = value?.toString().trim() ?? '';
        if (declared.contains(typeId) && text.isNotEmpty) {
          result[typeId] = text;
        }
      });
      return result;
    }

    Map<String, Map<String, dynamic>> readObjectMap(String key) {
      final dynamic raw = json[key];
      if (raw is! Map) return <String, Map<String, dynamic>>{};
      final Set<String> declared = types.toSet();
      final Map<String, Map<String, dynamic>> result =
          <String, Map<String, dynamic>>{};
      raw.forEach((dynamic key, dynamic value) {
        final String typeId = key.toString();
        if (declared.contains(typeId) && value is Map) {
          result[typeId] = Map<String, dynamic>.from(value);
        }
      });
      return result;
    }

    final Map<String, Map<String, dynamic>> schemas = readObjectMap(
      'typeSchemas',
    );
    final Map<String, Map<String, dynamic>> examples = readObjectMap(
      'typeExamples',
    );
    final dynamic sharedSchema = json['questionSchema'];
    final dynamic sharedExample = json['questionExample'];
    for (final String type in types) {
      if (!schemas.containsKey(type) && sharedSchema is Map) {
        schemas[type] = Map<String, dynamic>.from(sharedSchema);
      }
      if (!examples.containsKey(type) && sharedExample is Map) {
        examples[type] = Map<String, dynamic>.from(sharedExample);
      }
    }

    return PluginManifest(
      id: id,
      name: name,
      version: version,
      apiVersion: apiVersion,
      types: types,
      description: json['description']?.toString() ?? '',
      typeNames: readStringMap('typeNames'),
      typeDescriptions: readStringMap('typeDescriptions'),
      typeSchemas: schemas,
      typeExamples: examples,
      builtin: builtin,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'version': version,
    'apiVersion': apiVersion,
    'types': types,
    'description': description,
    if (typeNames.isNotEmpty) 'typeNames': typeNames,
    if (typeDescriptions.isNotEmpty) 'typeDescriptions': typeDescriptions,
    if (typeSchemas.isNotEmpty) 'typeSchemas': typeSchemas,
    if (typeExamples.isNotEmpty) 'typeExamples': typeExamples,
    'builtin': builtin,
  };
}

/// 插件目录、导入、下载和卸载。
///
/// 目录布局：`App Support/plugins/<id>/manifest.json`。
/// 插件 zip 内可以根目录直接放 manifest.json，也可以套一层 `<id>/`。
class PluginManager {
  PluginManager._();

  static const String builtinId = 'standard';
  static const String manifestName = 'manifest.json';
  static const String configPageName = 'config.html';
  static const String configFileName = 'config.json';
  static const int supportedApiVersion = 1;
  static const int _maxZipBytes = 20 * 1024 * 1024;
  static const int _maxFiles = 500;
  static const int _maxConfigBytes = 256 * 1024;

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{1,31}$');

  static bool isValidId(String id) => _idPattern.hasMatch(id);

  /// 插件根目录（不存在时创建）。
  static Future<Directory> directory() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory(
      '${support.path}${Platform.pathSeparator}plugins',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 把随包发布的内置插件资源同步到插件目录。
  ///
  /// 用 AssetManifest 列出 `assets/plugins/standard/` 下所有文件（含 KaTeX
  /// 字体），按二进制原样写入；standard 和第三方插件走同一套 WebView 协议。
  static Future<void> ensureBuiltin() async {
    final Directory dir = await directory();
    final Directory target = Directory(
      '${dir.path}${Platform.pathSeparator}$builtinId',
    );
    await target.create(recursive: true);

    const String prefix = 'assets/plugins/$builtinId/';
    try {
      final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(
        rootBundle,
      );
      for (final String asset in manifest.listAssets()) {
        if (!asset.startsWith(prefix)) continue;
        final data = await rootBundle.load(asset);
        final String relative = asset.substring(prefix.length);
        final File file = File(
          '${target.path}${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
    } catch (error) {
      debugPrint('同步内置插件资源失败：$error');
    }
  }

  /// 插件入口 HTML 的绝对路径；没有 index.html 时返回 null。
  static Future<String?> entryFile(String id) async {
    final Directory dir = await directory();
    final File entry = File(
      '${dir.path}${Platform.pathSeparator}$id'
      '${Platform.pathSeparator}index.html',
    );
    return await entry.exists() ? entry.path : null;
  }

  /// 插件配置页 `config.html` 的绝对路径；没有配置页时返回 null。
  static Future<String?> configPageFile(String id) async {
    final Directory dir = await directory();
    final File page = File(
      '${dir.path}${Platform.pathSeparator}$id'
      '${Platform.pathSeparator}$configPageName',
    );
    return await page.exists() ? page.path : null;
  }

  /// 读取插件自己的 `config.json`；文件不存在或为空时返回空对象。
  static Future<Map<String, dynamic>> readConfig(String id) async {
    if (!isValidId(id)) throw const PluginException('插件 id 不合法');
    final Directory dir = await directory();
    final File file = File(
      '${dir.path}${Platform.pathSeparator}$id'
      '${Platform.pathSeparator}$configFileName',
    );
    if (!await file.exists()) return <String, dynamic>{};

    try {
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return <String, dynamic>{};
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const PluginException('config.json 根节点必须是对象');
      }
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      if (error is PluginException) rethrow;
      throw PluginException('读取插件配置失败：$error');
    }
  }

  /// 写入插件自己的 `config.json`；配置只保存在插件目录下。
  static Future<void> writeConfig(
    String id,
    Map<String, dynamic> config,
  ) async {
    if (!isValidId(id)) throw const PluginException('插件 id 不合法');
    final Directory dir = await directory();
    final Directory target = Directory(
      '${dir.path}${Platform.pathSeparator}$id',
    );
    if (!await target.exists()) {
      throw const PluginException('插件未安装');
    }

    final String raw = const JsonEncoder.withIndent('  ').convert(config);
    if (utf8.encode(raw).length > _maxConfigBytes) {
      throw const PluginException('插件配置太大（超过 256 KB）');
    }
    await File('${target.path}${Platform.pathSeparator}$configFileName')
        .writeAsString(raw, flush: true);
  }

  /// 列出已安装插件，内置的排在最前。
  static Future<List<PluginManifest>> list() async {
    await ensureBuiltin();
    final Directory dir = await directory();
    final List<PluginManifest> plugins = <PluginManifest>[];

    try {
      await for (final FileSystemEntity entity in dir.list(
        followLinks: false,
      )) {
        if (entity is! Directory) continue;
        final File manifest = File(
          '${entity.path}${Platform.pathSeparator}$manifestName',
        );
        if (!await manifest.exists()) continue;
        try {
          final dynamic decoded = jsonDecode(await manifest.readAsString());
          if (decoded is! Map) continue;
          final String folder = _baseName(entity.path);
          final bool builtin = folder == builtinId;
          plugins.add(
            PluginManifest.fromJson(
              Map<String, dynamic>.from(decoded),
              builtin: builtin,
            ),
          );
        } catch (error) {
          debugPrint('读取插件清单失败：${entity.path} $error');
        }
      }
    } catch (error) {
      debugPrint('扫描插件目录失败：$error');
    }

    plugins.sort((PluginManifest a, PluginManifest b) {
      if (a.builtin != b.builtin) return a.builtin ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return plugins;
  }

  /// 按 id 查插件；不存在返回 null。
  static Future<PluginManifest?> find(String id) async {
    final List<PluginManifest> plugins = await list();
    for (final PluginManifest plugin in plugins) {
      if (plugin.id == id) return plugin;
    }
    return null;
  }

  static Future<bool> isInstalled(String id) async => await find(id) != null;

  /// 把用户选择的 zip 文件安装到插件目录。
  static Future<PluginManifest> importZip(File zip) async {
    final Uint8List bytes = await zip.readAsBytes();
    return importZipBytes(bytes);
  }

  /// 从 zip 字节安装插件；同名非内置插件会被覆盖。
  static Future<PluginManifest> importZipBytes(Uint8List bytes) async {
    if (bytes.length > _maxZipBytes) {
      throw const PluginException('插件包太大（超过 20 MB）');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } on PluginException {
      rethrow;
    } catch (error) {
      throw PluginException('无法读取 zip：$error');
    }
    if (archive.length > _maxFiles) {
      throw const PluginException('插件包文件太多（超过 500 个）');
    }

    final Directory root = await directory();
    final Directory staging = Directory(
      '${root.path}${Platform.pathSeparator}'
      '.import-${DateTime.now().microsecondsSinceEpoch}',
    );
    await staging.create(recursive: true);

    try {
      for (final ArchiveFile entry in archive) {
        if (!entry.isFile) continue;
        final String name = entry.name.replaceAll('\\', '/');
        if (name.startsWith('/') ||
            name.contains('..') ||
            RegExp(r'^[A-Za-z]:').hasMatch(name)) {
          throw PluginException('插件包包含非法路径：$name');
        }
        final File file = File('${staging.path}${Platform.pathSeparator}$name');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>, flush: true);
      }

      final File? manifestFile = _findManifest(staging);
      if (manifestFile == null) {
        throw const PluginException('插件包里没有 manifest.json');
      }

      final dynamic decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map) {
        throw const PluginException('manifest.json 根节点必须是对象');
      }
      final PluginManifest manifest = PluginManifest.fromJson(
        Map<String, dynamic>.from(decoded),
        builtin: false,
      );
      if (manifest.id == builtinId) {
        throw const PluginException('不能覆盖内置插件 $builtinId');
      }

      final Directory target = Directory(
        '${root.path}${Platform.pathSeparator}${manifest.id}',
      );
      String? existingConfig;
      if (await target.exists()) {
        // 升级插件时保留用户已保存的配置，避免被 zip 内默认配置覆盖。
        final File config = File(
          '${target.path}${Platform.pathSeparator}$configFileName',
        );
        if (await config.exists()) {
          existingConfig = await config.readAsString();
        }
        await target.delete(recursive: true);
      }
      await manifestFile.parent.rename(target.path);
      if (existingConfig != null) {
        await File('${target.path}${Platform.pathSeparator}$configFileName')
            .writeAsString(existingConfig, flush: true);
      }
      return manifest;
    } finally {
      if (await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          // 清理失败不影响安装结果
        }
      }
    }
  }

  /// 从 URL 下载 zip 并安装。
  static Future<PluginManifest> download(String url) async {
    final Uri uri;
    try {
      uri = Uri.parse(url.trim());
    } on FormatException {
      throw const PluginException('下载地址格式不正确');
    }
    if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const PluginException('下载地址必须是 http/https');
    }

    final http.Client client = http.Client();
    try {
      final http.Response response = await client
          .get(uri)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw PluginException('下载失败（HTTP ${response.statusCode}）');
      }
      if (response.bodyBytes.length > _maxZipBytes) {
        throw const PluginException('插件包太大（超过 20 MB）');
      }
      return await importZipBytes(response.bodyBytes);
    } on PluginException {
      rethrow;
    } on http.ClientException catch (error) {
      throw PluginException('网络请求失败：${error.message}');
    } catch (error) {
      throw PluginException('下载失败：$error');
    } finally {
      client.close();
    }
  }

  /// 卸载插件；内置插件不可卸载。
  static Future<void> uninstall(String id) async {
    if (id == builtinId) {
      throw const PluginException('内置插件不可卸载');
    }
    final Directory dir = await directory();
    final Directory target = Directory(
      '${dir.path}${Platform.pathSeparator}$id',
    );
    if (!await target.exists()) return;
    await target.delete(recursive: true);
  }

  /// 在 staging 里找最浅的 manifest.json（最多两层）。
  static File? _findManifest(Directory staging) {
    File? best;
    int bestDepth = 99;
    for (final FileSystemEntity entity in staging.listSync(recursive: true)) {
      if (entity is! File || _baseName(entity.path) != manifestName) continue;
      final String relative = entity.path
          .substring(staging.path.length)
          .replaceAll('\\', '/');
      final int depth = relative
          .split('/')
          .where((String s) => s.isNotEmpty)
          .length;
      if (depth < bestDepth) {
        best = entity;
        bestDepth = depth;
      }
    }
    return best;
  }

  static String _baseName(String path) {
    final int index = path.replaceAll('\\', '/').lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }
}
