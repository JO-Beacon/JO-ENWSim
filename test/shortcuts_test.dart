// 快捷键：默认值、同一个键位去重。
//
// 规矩：**一个键只能给一个动作用**。后设的赢，先前用着这个键的动作被清空
// （变成“未设置”，不会默默跟着默认值跑）。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/shortcuts.dart';

void main() {
  test('默认值：回车换行、Ctrl+回车发送', () {
    expect(joFallback(JoKey.send), 'Ctrl+Enter');
    expect(joFallback(JoKey.newline), 'Enter');
  });

  test('同一个键位：后设的赢，旧的动作被清空', () {
    final Map<String, String> k = joSetKey(
      joDefaultKeys(),
      JoKey.newline,
      'Ctrl+Enter',
    );
    expect(k[JoKey.newline], 'Ctrl+Enter');
    expect(k[JoKey.send], '');
    // 别的没动。
    expect(k[JoKey.settings], 'Ctrl+,');
  });

  test('大小写 / 空格 / 修饰键顺序 / 同义词都算同一个键', () {
    expect(joSameKey('Ctrl+Enter', 'ctrl + enter'), isTrue);
    expect(joSameKey('Ctrl+Shift+E', 'Shift+Ctrl+E'), isTrue);
    expect(joSameKey('esc', 'Escape'), isTrue);
    expect(joSameKey('control+n', 'Ctrl+N'), isTrue);
  });

  test('空 = 没绑，不跟任何键相等', () {
    expect(joSameKey('', ''), isFalse);
    expect(joSameKey('', 'Enter'), isFalse);
    // 清空一条不会把别人也清掉。
    final Map<String, String> k = joSetKey(joDefaultKeys(), JoKey.send, '');
    expect(k[JoKey.send], '');
    expect(k[JoKey.newline], 'Enter');
  });

  test('撞键时清空的动作，实际就没绑定了（不落回默认值）', () {
    final Map<String, String> k = joSetKey(
      joDefaultKeys(),
      JoKey.send,
      'Enter', // 撞上默认的“换行”
    );
    expect(k[JoKey.newline], '');
    // 界面与逻辑取值：先看表里存的，空串就真的是空。
    final String newline = k[JoKey.newline] ?? joFallback(JoKey.newline);
    expect(newline, '');
    expect(joActivator(newline), isNull);
  });
}
