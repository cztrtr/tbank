import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// 检查并申请“所有文件访问”权限；只在 Android 上需要。
///
/// 项目采用按路径读写题库的方案，所以 Android 11+ 需要
/// MANAGE_EXTERNAL_STORAGE；Android 10 及以下退回传统存储权限。
/// 申请流程会先弹说明，再跳系统设置，由用户手动打开开关。
class StoragePermission {
  const StoragePermission._();

  /// 只检查，不弹窗；用于页面初始化或从设置页返回时判断。
  ///
  /// - Android 11+：看 MANAGE_EXTERNAL_STORAGE；
  /// - Android 10 及以下：看传统 READ/WRITE_EXTERNAL_STORAGE。
  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    // Android 10 及以下走传统存储权限
    return Permission.storage.isGranted;
  }

  /// 没有权限时先弹说明，再跳系统设置；返回最终是否可用。
  ///
  /// 调用方应该在真正读写文件之前 await 这个方法，
  /// 返回 false 时不要继续扫描或复制文件。
  static Future<bool> ensure(BuildContext context) async {
    if (!Platform.isAndroid) return true;
    if (await isGranted()) return true;

    if (!context.mounted) return false;

    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要文件访问权限'),
        content: const Text(
          '读取和保存题库需要访问手机存储。\n'
          '接下来会打开系统设置，请找到本应用并允许“所有文件访问”。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    if (go != true) return false;

    // Android 11+：跳“所有文件访问”设置页
    final manage = await Permission.manageExternalStorage.request();
    if (manage.isGranted) return true;

    // Android 10 及以下：传统存储权限
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }
}