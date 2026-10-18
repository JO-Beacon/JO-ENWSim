// Tavily 的 Search / Extract。
//
// 文档：`AGENTS/docs-tavily/search.md`（OpenAPI 原文）、`AGENTS/docs-tavily/extract.md`
//   POST https://api.tavily.com/search
//   POST https://api.tavily.com/extract
// 鉴权：`Authorization: Bearer tvly-...`
//
// 与 DeepSeek 那套的区别（这就是为什么不能共用一份请求体）：
//   · 搜索在 `/search`（没有 `/v1` 前缀），取正文是 `/extract` 而不是 `/fetch`；
//   · 「要不要正文」不是布尔，而是 `include_raw_content`；
//   · 结果里正文叫 `raw_content`，摘要叫 `content`；
//   · 错误体是 `{"detail":{"error": "..."}}`，不是 OpenAI 那种 `{"error":{...}}`，
//     而且有 432 / 433 两个它自己的码（额度/套餐超限）。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'search_types.dart';

class TavilySearch {
  const TavilySearch({this.base = 'https://api.tavily.com'});

  final String base;

  static const Duration _timeout = Duration(seconds: 30);

  Future<SearchOutcome> search(
    String apiKey,
    String query, {
    int count = 5,
    bool needContent = false,
    http.Client? client,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return const SearchOutcome(ok: false, message: '搜索词是空的');
    }
    final Map<String, Object?> body = <String, Object?>{
      'query': q,
      'max_results': count.clamp(1, 20),
      'search_depth': 'basic',
      'include_raw_content': needContent,
    };
    final http.Response r;
    try {
      r = await (client ?? http.Client())
          .post(
            _uri('/search'),
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

    final Object? j = _decode(r.body);
    if (j is! Map) {
      return SearchOutcome(ok: false, message: '响应不是 JSON：${_short(r.body)}');
    }
    final Object? list = j['results'];
    if (list is! List) {
      return SearchOutcome(ok: false, message: '没有 results：${_short(r.body)}');
    }
    final List<SearchHit> hits = <SearchHit>[
      for (final Object? e in list)
        if (e is Map)
          SearchHit(
            title: '${e['title'] ?? ''}',
            url: '${e['url'] ?? ''}',
            // Tavily：content 是短摘要，raw_content 是正文。
            snippet: '${e['content'] ?? ''}',
            content: '${e['raw_content'] ?? ''}',
            date: e['published_date'] as String?,
            score: (e['score'] is num) ? (e['score'] as num).toDouble() : null,
          ),
    ];
    final String answer = '${j['answer'] ?? ''}';
    return SearchOutcome(
      ok: true,
      message: hits.isEmpty
          ? '没有搜到结果'
          : (answer.trim().isEmpty
                ? '${hits.length} 条结果'
                : '${hits.length} 条结果（带摘要）'),
      hits: hits,
    );
  }

  /// 取一页正文。Tavily 叫 Extract，一次可以给多个 URL。
  Future<FetchOutcome> extract(
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
            _uri('/extract'),
            headers: _headers(apiKey),
            body: jsonEncode(<String, Object?>{
              'urls': <String>[u],
            }),
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
    final Object? list = j['results'];
    if (list is! List || list.isEmpty) {
      // 失败的那几条在 `failed_results` 里，照实说。
      final Object? failed = j['failed_results'];
      final String why =
          (failed is List && failed.isNotEmpty && failed.first is Map)
          ? '${(failed.first as Map)['error'] ?? ''}'
          : '';
      return FetchOutcome(
        ok: false,
        message: why.isEmpty ? '没取到内容' : '没取到内容：$why',
      );
    }
    final Object? first = list.first;
    if (first is! Map) {
      return const FetchOutcome(ok: false, message: 'results 里不是对象');
    }
    final String content = '${first['raw_content'] ?? ''}';
    return FetchOutcome(
      ok: true,
      message: '取到了 ${content.length} 字',
      title: '${first['title'] ?? ''}',
      content: content,
    );
  }

  // ————————————————————————————— 内部

  Uri _uri(String path) =>
      Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> _headers(String apiKey) => <String, String>{
    'Authorization': 'Bearer ${apiKey.trim()}',
    // 必须带 charset：http 包不写时按 latin1 编码请求体，中文会抛。
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json',
  };

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// 错误码翻译。**Tavily 自己的那套**，包括 432 / 433。
  static String _httpMessage(int code, String body) {
    final Object? j = _decode(body);
    String detail = '';
    if (j is Map) {
      final Object? d = j['detail'];
      if (d is Map && d['error'] != null) detail = '${d['error']}';
      if (detail.isEmpty && d is String) detail = d;
    }
    if (detail.isEmpty) detail = _short(body);
    final String hint =
        <int, String>{
          400: '请求不对',
          401: 'API Key 不对（要 tvly- 开头的那个）',
          422: '参数校验没过',
          429: '请求太快了（限流），按 Retry-After 等一会儿',
          432: '额度超了（key 或套餐的上限）',
          433: '按量付费的上限超了',
          500: '服务端出错',
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
