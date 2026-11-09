import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// 作答图片的来源，页面不直接依赖 image_picker。
enum AnswerImageSource { camera, gallery }

/// 选择作答图片失败时抛出，[message] 可直接展示给用户。
class AnswerImageException implements Exception {
  const AnswerImageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 作答图片的选择与压缩。
///
/// 统一限制：最多 4 张、单张 5 MB、合计 10 MB；压缩到长边 1600，
/// 控制发给 AI 的 base64 体积。页面只负责弹来源菜单和提示。
class AnswerImagePicker {
  AnswerImagePicker._();

  static const int maxImages = 4;
  static const int maxImageBytes = 5 * 1024 * 1024;
  static const int maxTotalBytes = 10 * 1024 * 1024;

  /// 选一张图片；用户取消返回 null，校验失败抛 [AnswerImageException]。
  static Future<Uint8List?> pick(AnswerImageSource source) async {
    final XFile? picked = await ImagePicker().pickImage(
      source: source == AnswerImageSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked == null) return null;

    final Uint8List bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return null;
    if (bytes.length > maxImageBytes) {
      throw const AnswerImageException('图片太大了（超过 5 MB），请换一张');
    }
    return bytes;
  }
}
