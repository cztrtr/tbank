/// 插件运行时开关。
///
/// 正式启动时打开；widget 测试默认关闭，继续用原生练习页，
/// 这样不用为了 WebView 给每个测试准备平台实现。
class PluginRuntime {
  PluginRuntime._();

  static bool enabled = false;
}
