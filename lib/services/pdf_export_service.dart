import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/question_bank.dart';
import '../widgets/math_text.dart';
import 'bank_io.dart';

/// 把题库或错题本导出成适合打印/分享的 A4 PDF。
///
/// 题目卡片先用 Flutter 排好版（MathText 负责公式），再截图放进 PDF。
/// 这样中文、LaTeX、选项和配图不会因为 PDF 端缺字体/公式引擎而乱掉。
class PdfExportService {
  PdfExportService._();

  static const double _cardWidth = 760;
  static const double _cardPixelRatio = 2.0;
  static const double _margin = 36;

  /// 导出 [fileUri] 指向的题库；[sourceDirectoryRef] 用于读取题目配图。
  ///
  /// [title] 是封面标题，[fileName] 是不含扩展名的建议文件名。
  static Future<String?> export({
    required BuildContext context,
    required String fileUri,
    required String sourceDirectoryRef,
    required String title,
    required String fileName,
    Future<String?> Function(Uint8List bytes, String suggestedName)? saveFile,
  }) async {
    final QuestionBank bank = QuestionCodec.decode(
      await BankIo.readText(fileUri),
    );
    if (bank.questions.isEmpty) {
      throw StateError('这个题库没有题目，无法导出');
    }
    if (!context.mounted) return null;

    final ValueNotifier<String> status = ValueNotifier<String>(
      '正在排版 0 / ${bank.questions.length}',
    );
    BuildContext? progressContext;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          progressContext = dialogContext;
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('正在导出 PDF'),
              content: ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (BuildContext context, String value, Widget? _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(value),
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);

    try {
      final pw.Document document = pw.Document(theme: await _documentTheme());
      await _addCover(document, title, bank.questions.length);

      final List<Uint8List> cardPngs = <Uint8List>[];
      for (int i = 0; i < bank.questions.length; i++) {
        if (!context.mounted) throw StateError('导出页面已关闭');
        final Question question = bank.questions[i];
        status.value = '正在排版 ${i + 1} / ${bank.questions.length}';
        final Uint8List? imageBytes = await _loadQuestionImage(
          sourceDirectoryRef,
          question,
        );
        if (!context.mounted) throw StateError('导出页面已关闭');
        if (imageBytes != null && imageBytes.isNotEmpty) {
          // 先让 Image.memory 解码进缓存；否则首帧截图可能还没有配图。
          await precacheImage(MemoryImage(imageBytes), context);
        }
        if (!context.mounted) throw StateError('导出页面已关闭');
        cardPngs.add(
          await _captureQuestion(
            context,
            question: question,
            number: i + 1,
            imageBytes: imageBytes,
          ),
        );
      }

      // 短题卡自动拼到同一页，长解析才切页，避免一题一页全是空白。
      await _addQuestionPages(document, cardPngs);

      final Uint8List bytes = await document.save();
      final String safeName = _safeFileName(fileName);
      final String? path = saveFile != null
          ? await saveFile(bytes, safeName)
          : await _savePdf(bytes: bytes, suggestedName: safeName);
      if (path != null) status.value = '已导出：$path';
      return path;
    } finally {
      if (progressContext != null && progressContext!.mounted) {
        Navigator.of(progressContext!).pop();
      }
    }
  }

  static Future<pw.ThemeData> _documentTheme() async {
    final pw.Font regular = pw.Font.ttf(
      await rootBundle.load(
        'assets/plugins/standard/fonts/AlibabaPuHuiTi-3-55-Regular.ttf',
      ),
    );
    final pw.Font bold = pw.Font.ttf(
      await rootBundle.load(
        'assets/plugins/standard/fonts/AlibabaPuHuiTi-3-85-Bold.ttf',
      ),
    );
    return pw.ThemeData.withFont(base: regular, bold: bold);
  }

  static Future<void> _addCover(
    pw.Document document,
    String title,
    int count,
  ) async {
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(48),
        build: (pw.Context _) {
          return pw.Center(
            child: pw.Column(
              mainAxisSize: pw.MainAxisSize.min,
              children: <pw.Widget>[
                pw.Text(
                  'TBank 题目导出',
                  style: pw.TextStyle(
                    fontSize: 30,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromHex('#1D4ED8'),
                  ),
                ),
                pw.SizedBox(height: 18),
                pw.Text(
                  title,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(fontSize: 20),
                ),
                pw.SizedBox(height: 10),
                pw.Text(
                  '共 $count 题',
                  style: pw.TextStyle(
                    fontSize: 13,
                    color: PdfColor.fromHex('#666666'),
                  ),
                ),
                pw.SizedBox(height: 36),
                pw.Container(
                  width: 120,
                  height: 3,
                  color: PdfColor.fromHex('#1D4ED8'),
                ),
                pw.SizedBox(height: 30),
                pw.Text(
                  '生成时间：${DateTime.now().toString().substring(0, 19)}',
                  style: pw.TextStyle(
                    fontSize: 11,
                    color: PdfColor.fromHex('#888888'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static Future<Uint8List?> _loadQuestionImage(
    String directoryRef,
    Question question,
  ) async {
    if (!question.hasImage) return null;
    try {
      return await BankIo.readSiblingBytes(directoryRef, question.image);
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _captureQuestion(
    BuildContext context, {
    required Question question,
    required int number,
    required Uint8List? imageBytes,
  }) async {
    final GlobalKey boundaryKey = GlobalKey();
    final OverlayState overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (BuildContext _) {
        return Positioned(
          left: 0,
          top: 0,
          width: _cardWidth,
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.01,
              child: RepaintBoundary(
                key: boundaryKey,
                child: Material(
                  color: Colors.white,
                  child: PdfQuestionCard(
                    question: question,
                    number: number,
                    imageBytes: imageBytes,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    try {
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final RenderRepaintBoundary boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(
        pixelRatio: _cardPixelRatio,
      );
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      if (data == null) throw StateError('题目卡片截图失败');
      return data.buffer.asUint8List();
    } finally {
      entry.remove();
    }
  }

  /// 把题目截图按页高打包：短题尽量同页，长题才裁成连续图片页。
  static Future<void> _addQuestionPages(
    pw.Document document,
    List<Uint8List> cardPngs,
  ) async {
    const double gap = 10;
    const double safety = 4;
    final double contentWidth = PdfPageFormat.a4.width - _margin * 2;
    final double contentHeight = PdfPageFormat.a4.height - _margin * 2 - safety;

    final List<List<Uint8List>> pages = <List<Uint8List>>[];
    List<Uint8List> current = <Uint8List>[];
    double used = 0;

    void flush() {
      if (current.isEmpty) return;
      pages.add(current);
      current = <Uint8List>[];
      used = 0;
    }

    for (final Uint8List png in cardPngs) {
      final ui.Codec codec = await ui.instantiateImageCodec(png);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;
      final double cardHeight = contentWidth * image.height / image.width;

      if (cardHeight <= contentHeight) {
        final double needed = (current.isEmpty ? 0 : gap) + cardHeight;
        if (used + needed <= contentHeight) {
          current.add(png);
          used += needed;
        } else {
          flush();
          current.add(png);
          used = cardHeight;
        }
      } else {
        // 长题先尽量填满当前页剩余空间；剩余空间太窄就换新页。
        double firstAvailable = contentHeight - used - gap;
        if (current.isEmpty || firstAvailable < 120) {
          flush();
          firstAvailable = contentHeight;
        }
        final List<_PdfSlice> slices = await _sliceImage(
          image,
          contentWidth: contentWidth,
          firstHeight: firstAvailable,
          pageHeight: contentHeight,
        );
        for (int i = 0; i < slices.length; i++) {
          if (current.isNotEmpty) used += gap;
          current.add(slices[i].png);
          used += slices[i].height;
          if (i < slices.length - 1) flush();
        }
      }
      image.dispose();
    }
    flush();

    for (final List<Uint8List> page in pages) {
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(_margin),
          build: (pw.Context _) {
            return pw.Align(
              alignment: pw.Alignment.topCenter,
              child: pw.Column(
                mainAxisSize: pw.MainAxisSize.min,
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: <pw.Widget>[
                  for (int i = 0; i < page.length; i++) ...<pw.Widget>[
                    if (i > 0) pw.SizedBox(height: gap),
                    pw.Image(pw.MemoryImage(page[i]), width: contentWidth),
                  ],
                ],
              ),
            );
          },
        ),
      );
    }
  }

  /// 把一张超长题卡按页面高度裁成若干段。
  static Future<List<_PdfSlice>> _sliceImage(
    ui.Image source, {
    required double contentWidth,
    required double firstHeight,
    required double pageHeight,
  }) async {
    final double scale = contentWidth / source.width;
    final List<_PdfSlice> slices = <_PdfSlice>[];
    int top = 0;
    double available = firstHeight;
    while (top < source.height) {
      final int rows = (available / scale).floor().clamp(
        1,
        source.height - top,
      );
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        source,
        ui.Rect.fromLTWH(
          0,
          top.toDouble(),
          source.width.toDouble(),
          rows.toDouble(),
        ),
        ui.Rect.fromLTWH(0, 0, source.width.toDouble(), rows.toDouble()),
        ui.Paint(),
      );
      final ui.Image sliced = await recorder.endRecording().toImage(
        source.width,
        rows,
      );
      final ByteData? data = await sliced.toByteData(
        format: ui.ImageByteFormat.png,
      );
      sliced.dispose();
      if (data == null) break;
      slices.add(
        _PdfSlice(png: data.buffer.asUint8List(), height: rows * scale),
      );
      top += rows;
      available = pageHeight;
    }
    return slices;
  }

  static Future<String?> _savePdf({
    required Uint8List bytes,
    required String suggestedName,
  }) async {
    try {
      final Uri? saved = await FilePicker.saveFile(
        dialogTitle: '保存 PDF',
        fileName: '$suggestedName.pdf',
        mimeType: 'application/pdf',
        bytes: bytes,
      );
      if (saved == null) return null;
      // 文件选择器在移动端可能返回 content://，它已经写好字节；
      // 桌面端一般是 file://，按路径再兜底写一次。
      if (saved.scheme == 'file') {
        final String path = saved.toFilePath();
        final File file = File(path);
        if (!await file.exists()) {
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
        }
        return path;
      }
      return saved.toString();
    } catch (_) {
      final Directory support = await getApplicationSupportDirectory();
      final Directory dir = Directory(
        '${support.path}${Platform.pathSeparator}exports',
      );
      await dir.create(recursive: true);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}$suggestedName.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }
  }

  static String _safeFileName(String raw) {
    final String name = raw.trim().isEmpty ? '题目导出' : raw.trim();
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}

class _PdfSlice {
  const _PdfSlice({required this.png, required this.height});

  final Uint8List png;
  final double height;
}

/// 导出 PDF 的题目卡片。
class PdfQuestionCard extends StatelessWidget {
  const PdfQuestionCard({
    super.key,
    required this.question,
    required this.number,
    this.imageBytes,
  });

  final Question question;
  final int number;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1D4ED8),
    );
    final String typeLabel = switch (question.type) {
      QuestionType.singleChoice => '单选题',
      QuestionType.multipleChoice => '多选题',
      QuestionType.trueFalse => '判断题',
      QuestionType.fillBlank => '填空 / 简答',
    };
    final List<String> answers = question.correctAnswers;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                number.toString().padLeft(2, '0'),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  typeLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          MathText(
            question.question,
            style: const TextStyle(
              fontSize: 15,
              height: 1.55,
              color: Color(0xFF111827),
            ),
          ),
          if (imageBytes != null && imageBytes!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                imageBytes!,
                width: double.infinity,
                fit: BoxFit.contain,
              ),
            ),
          ],
          if (question.options.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            for (final QuestionOption option in question.options)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 7),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 22,
                      child: Text(
                        option.key,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Expanded(
                      child: MathText(
                        option.text,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (answers.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _SectionTitle(title: '答案', color: colors.primary),
            const SizedBox(height: 5),
            MathText(
              answers.join(' / '),
              style: const TextStyle(
                fontSize: 14,
                height: 1.5,
                color: Color(0xFF111827),
              ),
            ),
          ],
          if (question.analysis.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            _SectionTitle(title: '解析', color: colors.primary),
            const SizedBox(height: 5),
            MathText(
              question.analysis,
              style: const TextStyle(
                fontSize: 14,
                height: 1.6,
                color: Color(0xFF374151),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            height: 1,
            color: const Color(0xFFE5E7EB),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.color});

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color),
    );
  }
}
