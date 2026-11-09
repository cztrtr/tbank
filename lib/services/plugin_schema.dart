/// 插件私有数据 `pluginData` 的轻量 JSON Schema 校验。
///
/// 支持插件最常用的一组关键字：type / required / properties /
/// additionalProperties / items / enum / const / allOf / anyOf / oneOf
/// 以及字符串、数组、数字的长度/范围限制。不支持的 `$ref` 会直接报错，
/// 避免插件以为校验生效、实际被跳过。
class PluginSchemaValidator {
  PluginSchemaValidator._();

  static String? validate(Map<String, dynamic> schema, dynamic value) {
    return _validate(schema, value, r'$');
  }

  static String? _validate(
    Map<String, dynamic> schema,
    dynamic value,
    String path,
  ) {
    if (schema.containsKey(r'$ref')) {
      return '$path：暂不支持 \$ref，请把 schema 展开';
    }

    if (schema['allOf'] is List) {
      for (final dynamic item in schema['allOf'] as List) {
        if (item is! Map) continue;
        final String? error = _validate(
          Map<String, dynamic>.from(item),
          value,
          path,
        );
        if (error != null) return error;
      }
    }

    if (schema['anyOf'] is List) {
      bool matched = false;
      for (final dynamic item in schema['anyOf'] as List) {
        if (item is! Map) continue;
        if (_validate(Map<String, dynamic>.from(item), value, path) == null) {
          matched = true;
          break;
        }
      }
      if (!matched) return '$path：不满足 anyOf 中的任何一个 schema';
    }

    if (schema['oneOf'] is List) {
      int matched = 0;
      for (final dynamic item in schema['oneOf'] as List) {
        if (item is! Map) continue;
        if (_validate(Map<String, dynamic>.from(item), value, path) == null) {
          matched++;
        }
      }
      if (matched != 1) return '$path：必须恰好满足 oneOf 中的一个 schema';
    }

    final dynamic constValue = schema['const'];
    if (constValue != null && value != constValue) {
      return '$path：必须等于 ${constValue.toString()}';
    }

    if (schema['enum'] is List) {
      final List<dynamic> options = schema['enum'] as List;
      if (!options.any((dynamic item) => item == value)) {
        return '$path：必须是 ${options.join(' / ')} 之一';
      }
    }

    final dynamic rawType = schema['type'];
    if (rawType != null) {
      final List<String> types = rawType is List
          ? rawType.map((dynamic item) => item.toString()).toList()
          : <String>[rawType.toString()];
      if (!types.any((String type) => _matchesType(type, value))) {
        return '$path：类型应为 ${types.join(' / ')}';
      }
    }

    if (value is Map) {
      final dynamic rawRequired = schema['required'];
      if (rawRequired is List) {
        for (final dynamic item in rawRequired) {
          final String key = item.toString();
          if (!value.containsKey(key)) return '$path：缺少必填字段 $key';
        }
      }

      final dynamic rawProperties = schema['properties'];
      final Map<String, dynamic> properties = rawProperties is Map
          ? Map<String, dynamic>.from(rawProperties)
          : <String, dynamic>{};
      for (final MapEntry<String, dynamic> entry in properties.entries) {
        if (!value.containsKey(entry.key)) continue;
        final dynamic subSchema = entry.value;
        if (subSchema is Map) {
          final String? error = _validate(
            Map<String, dynamic>.from(subSchema),
            value[entry.key],
            '$path.${entry.key}',
          );
          if (error != null) return error;
        }
      }

      final dynamic additional = schema['additionalProperties'];
      if (additional == false) {
        for (final dynamic key in value.keys) {
          if (!properties.containsKey(key.toString())) {
            return '$path：不允许字段 $key';
          }
        }
      } else if (additional is Map) {
        for (final MapEntry<dynamic, dynamic> entry in value.entries) {
          if (properties.containsKey(entry.key.toString())) continue;
          final String? error = _validate(
            Map<String, dynamic>.from(additional),
            entry.value,
            '$path.${entry.key}',
          );
          if (error != null) return error;
        }
      }
    }

    if (value is List) {
      final dynamic rawMin = schema['minItems'];
      final dynamic rawMax = schema['maxItems'];
      if (rawMin is num && value.length < rawMin) {
        return '$path：至少需要 ${rawMin.toInt()} 项';
      }
      if (rawMax is num && value.length > rawMax) {
        return '$path：最多允许 ${rawMax.toInt()} 项';
      }
      final dynamic items = schema['items'];
      if (items is Map) {
        for (int i = 0; i < value.length; i++) {
          final String? error = _validate(
            Map<String, dynamic>.from(items),
            value[i],
            '$path[$i]',
          );
          if (error != null) return error;
        }
      }
    }

    if (value is String) {
      final dynamic minLength = schema['minLength'];
      final dynamic maxLength = schema['maxLength'];
      if (minLength is num && value.length < minLength) {
        return '$path：长度至少 ${minLength.toInt()}';
      }
      if (maxLength is num && value.length > maxLength) {
        return '$path：长度最多 ${maxLength.toInt()}';
      }
      final dynamic pattern = schema['pattern'];
      if (pattern is String) {
        try {
          if (!RegExp(pattern).hasMatch(value)) return '$path：格式不匹配';
        } catch (_) {
          return '$path：schema 里的 pattern 不是合法正则';
        }
      }
    }

    if (value is num) {
      final dynamic minimum = schema['minimum'];
      final dynamic maximum = schema['maximum'];
      if (minimum is num && value < minimum) {
        return '$path：不能小于 $minimum';
      }
      if (maximum is num && value > maximum) {
        return '$path：不能大于 $maximum';
      }
    }

    return null;
  }

  static bool _matchesType(String type, dynamic value) {
    return switch (type) {
      'object' => value is Map,
      'array' => value is List,
      'string' => value is String,
      'number' => value is num,
      'integer' =>
        value is int || (value is double && value == value.roundToDouble()),
      'boolean' => value is bool,
      'null' => value == null,
      _ => true,
    };
  }
}
