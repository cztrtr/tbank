import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/update_service.dart';

/// 更新地址的拼接规则（不涉及网络）。
void main() {
  group('UpdateService.apkUri', () {
    test('完整 APK 地址原样使用', () {
      expect(
        UpdateService.apkUri('https://abc.r9.cpolar.top/app-release.apk')
            .toString(),
        'https://abc.r9.cpolar.top/app-release.apk',
      );
    });

    test('只填服务器地址时自动补文件名', () {
      expect(
        UpdateService.apkUri('https://abc.r9.cpolar.top').toString(),
        'https://abc.r9.cpolar.top/app-release.apk',
      );
    });

    test('不带协议时自动补 https', () {
      expect(
        UpdateService.apkUri('abc.r9.cpolar.top').toString(),
        'https://abc.r9.cpolar.top/app-release.apk',
      );
    });

    test('带子路径时拼在路径后面', () {
      expect(
        UpdateService.apkUri('https://host/files').toString(),
        'https://host/files/app-release.apk',
      );
    });

    test('空输入抛 UpdateException', () {
      expect(
        () => UpdateService.apkUri('   '),
        throwsA(isA<UpdateException>()),
      );
    });

    test('没有域名时抛 UpdateException', () {
      expect(
        () => UpdateService.apkUri('https://'),
        throwsA(isA<UpdateException>()),
      );
    });
  });
}
