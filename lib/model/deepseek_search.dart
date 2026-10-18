// DeepSeek 的 Search / Fetch 接口（2026-10-17 开放）。
//
// 文档：`AGENTS/docs-deepseek/guide-search-fetch.md`
//   POST https://api.deepseek.com/v1/tools/search
//   POST https://api.deepseek.com/v1/tools/fetch
// 鉴权：`Authorization: Bearer <api key>`，JSON body。
// 计费：按**成功次数**算，每个端点 $0.75 / 1000 次。
//
// 只用这两个端点，不碰 chat/completions —— 那套在 `llm_client.dart` 里。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'search_types.dart';

// 结果类型是两家共用的（`search_types.dart`）；这里再导出一遍，
// 让只用到本文件的人不必多引一个文件。
export 'search_types.dart';

class DeepSeekSearch {
  const DeepSeekSearch({this.base = 'https://api.deepseek.com'});

  /// 服务地址。默认官方；自建代理就传别的。
  final String base;

  static const Duration _timeout = Duration(seconds: 25);

  /// 搜索。
  ///
  /// [count] 1–50；[needContent] 为真时每条结果带正文（更贵、更慢）。
  Future<SearchOutcome> search(
    String apiKey,
    String query, {
    int count = 10,
    bool needContent = false,
    http.Client? client,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return const SearchOutcome(ok: false, message: '搜索词是空的');
    }
    final Map<String, Object?> body = <String, Object?>{
      'query': q,
      'count': count.clamp(1, 50),
      'need_content': needContent,
    };
    final http.Response r;
    try {
      r = await (client ?? http.Client())
          .post(
            _uri('/v1/tools/search'),
            headers: _headers(apiKey),
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      return SearchOutcome(ok: false, message: '请求失败：$e');
    }

    if (r.statusCode < 200 || r.statusCode >= 300) {
      return SearchOutcome(
        ok: false,
        message: _httpMessage(r.statusCode, r.body),
      );
    }
    return _parseSearch(r.body);
  }

  /// 取一页网页正文。
  ///
  /// 文档写明：目标站点的可用性、访问策略都会影响结果，
  /// 取不到就是 404，**不代表请求本身错了**。
  Future<FetchOutcome> fetch(
    String apiKey,
    String url, {
    http.Client? client,
  }) async {
    final String u = url.trim();
    if (u.isEmpty) return const FetchOutcome(ok: false, message: '地址是空的');
    final http.Response r;
    try {
      r = await (client ?? http.Client())
          .post(
            _uri('/v1/tools/fetch'),
            headers: _headers(apiKey),
            body: jsonEncode(<String, Object?>{'url': u}),
          )
          .timeout(_timeout);
    } catch (e) {
      return FetchOutcome(ok: false, message: '请求失败：$e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      return FetchOutcome(
        ok: false,
        message: _httpMessage(r.statusCode, r.body),
      );
    }
    final Object? j = _decode(r.body);
    if (j is! Map) {
      return FetchOutcome(ok: false, message: '响应不是 JSON：${_short(r.body)}');
    }
    final String content = '${j['content'] ?? ''}';
    return FetchOutcome(
      ok: true,
      message: '取到了 ${content.length} 字',
      title: '${j['title'] ?? ''}',
      content: content,
    );
  }

  // ————————————————————————————— 内部

  Uri _uri(String path) =>
      Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> _headers(String apiKey) => <String, String>{
    'Authorization': 'Bearer ${apiKey.trim()}',
    // **必须带 charset**：`http` 包里不写 charset 时就按 latin1 编码请求体，
    // 遇到中文直接抛 “Contains invalid characters”。
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json',
  };

  SearchOutcome _parseSearch(String body) {
    final Object? j = _decode(body);
    if (j is! Map) {
      return SearchOutcome(ok: false, message: '响应不是 JSON：${_short(body)}');
    }
    final Object? list = j['results'];
    if (list is! List) {
      return SearchOutcome(ok: false, message: '没有 results：${_short(body)}');
    }
    final List<SearchHit> hits = <SearchHit>[
      for (final Object? e in list)
        if (e is Map)
          SearchHit(
            title: '${e['title'] ?? ''}',
            url: '${e['url'] ?? ''}',
            snippet: '${e['snippet'] ?? ''}',
            summary: '${e['summary'] ?? ''}',
            content: '${e['content'] ?? ''}',
            siteName: e['site_name'] as String?,
            date: e['date'] as String?,
            authority: (e['authority'] is num)
                ? (e['authority'] as num).toInt()
                : null,
            score: (e['rerank_score'] is num)
                ? (e['rerank_score'] as num).toDouble()
                : null,
          ),
    ];
    return SearchOutcome(
      ok: true,
      // 搜到 0 条是正常结果，不是错误（文档明写返回空数组）。
      message: hits.isEmpty ? '没有搜到结果' : '${hits.length} 条结果',
      hits: hits,
    );
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// 错误码翻译。**按这个接口的文档来**，不套 chat 那套。
  ///
  /// 优先用响应里的 `error.message`：厂商自己说的话比我们猜得准。
  static String _httpMessage(int code, String body) {
    final Object? j = _decode(body);
    String detail = '';
    if (j is Map && j['error'] is Map) {
      final Object? m = (j['error'] as Map)['message'];
      if (m != null) detail = '$m';
    }
    if (detail.isEmpty) detail = _short(body);
    final String hint =
        <int, String>{
          400: '请求格式不对',
          401: 'API Key 不对',
          402: '余额不足，去充值',
          403: '被安全策略拒了（Fetch 常见）',
          404: '取不到可用内容（页面不可达 / 被站点策略挡 / 正文提不出来）',
          408: '读请求体超时，可以重试',
          413: '请求体太大',
          429: '请求太快了（QPS 超限），等一会儿再试',
          500: '服务端出错，可以重试',
          504: '下游超时，可以重试',
        }[code] ??
        '请求失败';
    return 'HTTP $code · $hint：$detail';
  }

  static String _short(String s) {
    final String t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '（空的响应）';
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }
}
