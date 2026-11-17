import 'package:flutter_test/flutter_test.dart';
import 'package:tbank/services/secret_redactor.dart';

void main() {
  test('错误文本里的 DeepSeek Key 会被脱敏', () {
    final String text = SecretRedactor.redact(
      'Authorization: Bearer sk-abcdefghijklmnop123456 failed',
    );
    expect(text.contains('sk-abcdefghijklmnop123456'), isFalse);
    expect(text.contains('sk-***'), isTrue);
  });

  test('普通文本保持不变', () {
    expect(SecretRedactor.redact('题库读取失败'), '题库读取失败');
    expect(SecretRedactor.redactNullable(null), isNull);
  });
}
