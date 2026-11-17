import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/plugin_manager.dart';

void main() {
  test('apiVersion 2 只放行声明过的能力', () {
    final PluginManifest plugin = PluginManifest.fromJson(<String, dynamic>{
      'id': 'demo',
      'name': 'Demo',
      'version': '1.0.0',
      'apiVersion': 2,
      'types': <String>['demo'],
      'capabilities': <String>['ai', 'config'],
      'networkHosts': <String>['api.example.com', '.deepseek.com'],
    }, builtin: false);

    expect(plugin.allows('ai'), isTrue);
    expect(plugin.allows('config'), isTrue);
    expect(plugin.allows('fetch'), isFalse);
    expect(plugin.allows('clipboard'), isFalse);
    expect(plugin.networkHosts, <String>['api.example.com', '.deepseek.com']);
  });

  test('apiVersion 1 旧插件保持全量兼容', () {
    final PluginManifest plugin = PluginManifest.fromJson(<String, dynamic>{
      'id': 'legacy',
      'name': 'Legacy',
      'version': '1.0.0',
      'apiVersion': 1,
      'types': <String>['legacy'],
    }, builtin: false);

    expect(plugin.allows('fetch'), isTrue);
    expect(plugin.allows('readBank'), isTrue);
    expect(plugin.capabilities, isEmpty);
  });
}
