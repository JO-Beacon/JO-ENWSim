// 开源许可。
//
// 不用 Flutter 自带的 showLicensePage：它把框架的许可**按库文件重复几百遍**，
// 打开一看全是 Material。而 LicenseRegistry 只能加不能删，过滤不了。
//
// 这里自己走一遍许可清单，**按包名去重**：一个包一条。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'common.dart';
import 'icons.dart';

class LicensesPage extends StatefulWidget {
  const LicensesPage({super.key});

  @override
  State<LicensesPage> createState() => _LicensesPageState();
}

class _LicensesPageState extends State<LicensesPage> {
  /// 包名 → 许可正文。同名取最长的那份（重复注册时正文会缺斤少两）。
  Map<String, String>? _byName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Map<String, String> out = <String, String>{};
    await for (final LicenseEntry e in LicenseRegistry.licenses) {
      final String name = e.packages.isEmpty ? '(未署名)' : e.packages.first;
      final String text = e.paragraphs
          .map((LicenseParagraph p) => p.text)
          .join('\n\n')
          .trim();
      final String? old = out[name];
      if (old == null || text.length > old.length) out[name] = text;
    }
    if (!mounted) return;
    setState(() => _byName = out);
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Map<String, String>? m = _byName;
    return Container(
      color: p.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(JoSpace.s4),
            child: Row(
              children: <Widget>[
                JoIconAction(
                  icon: JoIcons.arrowLeft,
                  tip: '返回',
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: JoSpace.s4),
                Text(
                  '开源许可',
                  style: JoFonts.ui.copyWith(fontSize: 15, color: p.text),
                ),
                const Spacer(),
                if (m != null)
                  Text(
                    '一共有 ${m.length} 项',
                    style: JoFonts.meta.copyWith(color: p.secondary),
                  ),
              ],
            ),
          ),
          if (m == null)
            Padding(
              padding: const EdgeInsets.all(JoSpace.s4),
              child: Text(
                '正在读许可清单……',
                style: JoFonts.meta.copyWith(color: p.secondary),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: JoSpace.s4,
                  vertical: JoSpace.s2,
                ),
                children: <Widget>[
                  for (final MapEntry<String, String> e in m.entries)
                    JoTap(
                      onTap: () => _showText(e.key, e.value),
                      builder: (BuildContext c, bool hover, bool down) =>
                          Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: JoSpace.s3,
                              horizontal: JoSpace.s2,
                            ),
                            decoration: BoxDecoration(
                              color: hover
                                  ? p.surface
                                  : p.bg.withValues(alpha: 0),
                              border: Border(
                                bottom: BorderSide(color: p.border),
                              ),
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    e.key,
                                    style: JoFonts.ui.copyWith(
                                      fontSize: 13,
                                      color: p.text,
                                    ),
                                  ),
                                ),
                                Text(
                                  '看正文 →',
                                  style: JoFonts.meta.copyWith(color: p.accent),
                                ),
                              ],
                            ),
                          ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _showText(String name, String text) {
    showDialog<void>(
      context: context,
      builder: (BuildContext c) {
        final JoPalette p = JoTheme.of(c);
        return Dialog(
          backgroundColor: p.bg,
          shape: const RoundedRectangleBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(JoSpace.s4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          name,
                          style: JoFonts.ui.copyWith(
                            fontSize: 14,
                            color: p.text,
                          ),
                        ),
                      ),
                      JoButton(
                        text: '关闭',
                        onTap: () => Navigator.of(c).maybePop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      JoSpace.s4,
                      0,
                      JoSpace.s4,
                      JoSpace.s4,
                    ),
                    child: SelectableText(
                      text.isEmpty ? '（这份没有署名正文）' : text,
                      style: JoFonts.meta.copyWith(
                        color: p.secondary,
                        height: 1.7,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
