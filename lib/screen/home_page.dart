import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_config.dart';
import '../widgets/quote_card.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _backgroundAsset; // 当前随机选中的背景图

  bool _cardVisible = false; // 打卡卡片是否正在显示（控制入场/离场）
  bool _checkInDone = false; // 本次启动是否刚完成打卡（用于播放动画）
  bool _alreadyCheckedToday = false; // 今天是否已经打过卡（启动时判断）
  bool _cardRemoved = false; // 动画结束后从树上移除，避免继续拦截点击
  late final String _dateText; // 当天日期，形如 10/24

  @override
  void initState() {
    super.initState();
    _dateText = _formatDate(DateTime.now());
    // 启动时先判断今天是否已经打过卡
    _alreadyCheckedToday = AppConfig.hasCheckedInToday;
    _pickBackground();

    // 等第一帧渲染后再触发入场，避免页面一打开就是生硬的静态卡片
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _cardVisible = true);
      }
    });
  }

  /// 把日期格式化成 MM/DD。
  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$month/$day';
  }

  /// 从 assets/images/home_bg/ 里随机选一张背景。
  Future<void> _pickBackground() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);

      final images = manifest.listAssets().where((path) {
        final lower = path.toLowerCase();
        return path.startsWith('assets/images/home_bg/') &&
            (lower.endsWith('.jpg') ||
                lower.endsWith('.jpeg') ||
                lower.endsWith('.png') ||
                lower.endsWith('.webp'));
      }).toList();

      if (!mounted || images.isEmpty) return;

      final pick = images[Random().nextInt(images.length)];
      setState(() => _backgroundAsset = pick);
    } catch (error) {
      debugPrint('选择首页背景失败：$error');
    }
  }

  /// 卡片标题：未打卡 / 已打卡 / 刚打卡成功的动画状态。
  String get _title {
    if (_checkInDone) return 'HELLO';
    if (_alreadyCheckedToday) return '已打卡';
    return '打卡';
  }

  /// 点击卡片：交给 AppConfig 判断今天是否已打、是否断签，然后播动画。
  Future<void> _handleCheckIn() async {
    if (_checkInDone || _alreadyCheckedToday) return;

    // AppConfig 内部会判断：
    // - 今天已打：返回 false；
    // - 昨天打过：天数 +1；
    // - 断签/第一次：天数重置为 1。
    final success = await AppConfig.checkInToday();
    if (!mounted) return;

    if (!success) {
      // 今天已经打过，只切换成不可点击的“已打卡”状态，不播成功动画
      setState(() => _alreadyCheckedToday = true);
      return;
    }

    setState(() => _checkInDone = true);

    // 让 “HELLO” 和放大后的日期停留 1 秒
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    if (!mounted) return;

    // 触发卡片淡出 + 上滑离场
    setState(() => _cardVisible = false);

    // 等离场动画结束再从树上移除
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    setState(() => _cardRemoved = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Home'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _buildBackground(),
          // 让文字在复杂背景上仍然可读
          Container(color: Colors.black.withValues(alpha: 0.25)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: kToolbarHeight),
              child: Column(
                children: <Widget>[
                  if (_cardRemoved)
                    // 卡片离场后留下等高占位，避免下面的语录卡突然上跳
                    const SizedBox(height: 190 + 16)
                  else
                    _buildCheckInCard(context),
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: QuoteCard(),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    final asset = _backgroundAsset;

    if (asset == null) {
      return const ColoredBox(color: Color(0xFF2F6FED));
    }

    return Image.asset(
      asset,
      fit: BoxFit.cover, // 等比铺满，裁掉多余部分，不拉伸
      alignment: Alignment.center,
    );
  }

  /// 顶部居中的圆角正方形打卡卡片。
  ///
  /// 半透明 + 背景模糊，让下面的背景图透出来，同时保证文字可读。
  Widget _buildCheckInCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.topCenter,
      child: AnimatedSlide(
        offset: _cardVisible ? Offset.zero : const Offset(0, -0.15),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _cardVisible ? 1 : 0,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOut,
          child: IgnorePointer(
            ignoring: !_cardVisible,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: SizedBox.square(
                dimension: 190, // 圆角正方形
                child: Material(
                  color: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  elevation: 12,
                  shadowColor: Colors.black.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(30),
                  clipBehavior: Clip.antiAlias,
                  child: BackdropFilter(
                    // 毛玻璃：模糊卡片背后的背景图
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      color: colorScheme.surface.withValues(alpha: 0.55),
                      child: InkWell(
                        // 整个圆角正方形都可点击；今天已打过或刚打完则禁用
                        onTap: (_checkInDone || _alreadyCheckedToday)
                            ? null
                            : _handleCheckIn,
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: <Widget>[
                                // 打卡 -> HELLO，带淡入和轻微缩放
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 260),
                                  transitionBuilder: (child, animation) {
                                    final scale = Tween<double>(
                                      begin: 0.92,
                                      end: 1,
                                    ).animate(
                                      CurvedAnimation(
                                        parent: animation,
                                        curve: Curves.easeOutCubic,
                                      ),
                                    );
                                    return FadeTransition(
                                      opacity: animation,
                                      child: ScaleTransition(
                                        scale: scale,
                                        alignment: Alignment.center,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: Text(
                                    _title,
                                    key: ValueKey<String>(_title),
                                    style: TextStyle(
                                      fontSize: 30,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2,
                                      color: (_checkInDone ||
                                              _alreadyCheckedToday)
                                          ? colorScheme.primary
                                          : colorScheme.onSurface,
                                    ),
                                  ),
                                ),

                                // “已经打卡 xx 天” 点击后高度收缩并淡出
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 260),
                                  switchInCurve: Curves.easeOut,
                                  switchOutCurve: Curves.easeIn,
                                  transitionBuilder: (child, animation) {
                                    return SizeTransition(
                                      sizeFactor: animation,
                                      alignment: Alignment.center,
                                      child: FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: _checkInDone
                                      ? const SizedBox(
                                          key: ValueKey<String>(
                                            'count-hidden',
                                          ),
                                        )
                                      : ValueListenableBuilder<int>(
                                          key: const ValueKey<String>(
                                            'count-visible',
                                          ),
                                          valueListenable:
                                              AppConfig.clockOnNotifier,
                                          builder: (context, clockOn, _) {
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                '已经打卡 $clockOn 天',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                ),

                                const SizedBox(height: 10),

                                // 日期：点击后稍微放大并变色
                                AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 320),
                                  curve: Curves.easeOutCubic,
                                  style: TextStyle(
                                    fontSize: _checkInDone ? 22 : 14,
                                    fontWeight: _checkInDone
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    letterSpacing: _checkInDone ? 1.2 : 0,
                                    color: _checkInDone
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                  child: Text(_dateText),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
