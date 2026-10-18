// 选中文字的右键菜单里那几个词。
//
// 为什么需要这个：输入框用的是 `CupertinoTextField`，它的右键菜单文字取自
// `CupertinoLocalizations`。App 没挂任何本地化代理，于是落到 Flutter 的默认值
// —— 英文的 Cut / Copy / Paste / Select all。
//
// 这里只做一件事：把默认那套继承下来，**只改菜单上那几个词**。
// 不引 `flutter_localizations`（那会带进整份多语言表和一个 `intl` 依赖，
// 而界面目前只做中文）。

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

/// 中文的 Cupertino 文案。只改选中菜单相关的几条，其余沿用默认。
class JoCupertinoLocalizations extends DefaultCupertinoLocalizations {
  const JoCupertinoLocalizations();

  @override
  String get cutButtonLabel => '剪切';

  @override
  String get copyButtonLabel => '复制';

  @override
  String get pasteButtonLabel => '粘贴';

  @override
  String get selectAllButtonLabel => '全选';

  @override
  String get lookUpButtonLabel => '查询';

  @override
  String get searchWebButtonLabel => '在网页中搜索';

  @override
  String get shareButtonLabel => '共享';
}

/// 挂在 `MaterialApp.localizationsDelegates` 最前面：任何语言都用这份中文。
class JoCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const JoCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  /// 同步返回：异步的话界面会先空一帧（测试里甚至直接拿不到内容）。
  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      SynchronousFuture<CupertinoLocalizations>(
        const JoCupertinoLocalizations(),
      );

  @override
  bool shouldReload(JoCupertinoLocalizationsDelegate old) => false;
}
