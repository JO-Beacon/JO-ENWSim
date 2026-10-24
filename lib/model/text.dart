// 文本的小工具：统一行尾。
//
// Windows 的记事本、网页、聊天窗口复制出来的多行文字是 **CRLF**（`\r\n`）。
// `\r` 是控制字符、没有字形，画出来就是一个“豆腐块”（☒），
// 还会把 Markdown 的切块搞乱（`\r` 不换行，整段挤成一行）。
//
// 我们的规矩：**进库的文字只能是 LF**。

/// 把 CRLF / CR 统一成 LF。
///
/// 只动行尾，别的字符一个不改（空格、缩进、全角标点都原样）。
String joLf(String s) {
  if (!s.contains('\r')) return s;
  return s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}
