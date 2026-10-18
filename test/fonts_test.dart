// 字体：界面上只许有两种字 —— 思源黑体（Noto Sans SC）与思源宋体（Noto Serif SC）。
//
// 为什么要钉这条：元数据那套样式以前写的是 `fontFamily: 'monospace'`。
// 那是个**泛称，不是字体名**；Windows 上没有叫这个名字的字体族，
// 引擎找不到就落回自带的 Roboto（Material 那套观感），
// 而中文又落到系统字体 —— 同一行里两种字，看着就像“混进了 Material 字体”。

import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/theme/tokens.dart';

void main() {
  test('每一套文字样式都用思源，不用泛称字体', () {
    final Map<String, TextStyle> styles = <String, TextStyle>{
      'ui': JoFonts.ui,
      'body': JoFonts.body,
      'meta': JoFonts.meta,
    };
    for (final MapEntry<String, TextStyle> e in styles.entries) {
      expect(
        <String>{JoFonts.sans, JoFonts.serif},
        contains(e.value.fontFamily),
        reason: '${e.key} 的字体是 ${e.value.fontFamily}',
      );
      // 泛称（monospace / sans-serif / serif / system-ui）一律不许。
      expect(
        e.value.fontFamily,
        isNot(
          anyOf(<String>[
            'monospace',
            'sans-serif',
            'serif',
            'system-ui',
            'inherit',
          ]),
        ),
      );
    }
  });

  test('元数据那套也带数字等宽特性（以前靠等宽字体对齐编号）', () {
    expect(JoFonts.meta.fontFeatures, isNotNull);
    expect(
      JoFonts.meta.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  test('代码里不许再出现 fontFamily 写泛称', () {
    // tokens.dart 的注释里会提到 monospace（解释为什么不用），跳过它。
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.replaceAll(r'\', '/').endsWith('theme/tokens.dart')) continue;
      final String src = e.readAsStringSync();
      for (final String bad in <String>[
        "fontFamily: 'monospace'",
        'fontFamily: "monospace"',
        "fontFamily: 'sans-serif'",
        "fontFamily: 'system-ui'",
        "fontFamily: '.SF",
      ]) {
        if (src.contains(bad)) offenders.add('${e.path} → $bad');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
