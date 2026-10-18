// Tavily 的 Search / Extract。
//
// 文档：AGENTS/docs-tavily/search.md、extract.md
// 它跟 DeepSeek 那套**不是同一个形状**，所以单独一个客户端：
//   · 搜索是 `/search`（没 /v1 前缀），取正文是 `/extract`；
//   · 要正文用 `include_raw_content`，结果里正文叫 `raw_content`；
//   · 错误体是 `{"detail":{"error":...}}`，还有 432 / 433 两个自己的码。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/model/search_api.dart';
import 'package:joenws/model/tavily_search.dart';

http.Response json(String body, int code) => http.Response(
  body,
  code,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

void main() {
  const TavilySearch api = TavilySearch();

  test('search：请求体与 Bearer 头照文档', () async {
    late http.Request seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r;
      return json('''
{"results":[
  {"title":"T", "url":"https://a.example/1", "content":"短摘要",
   "raw_content":"正文", "score":0.81, "published_date":"Tue, 11 Mar 2025 17:00:00 GMT"}
]}''', 200);
    });

    final SearchOutcome r = await api.search(
      'tvly-test',
      '  leo messi ',
      count: 3,
      needContent: true,
      client: c,
    );

    expect(seen.url.toString(), 'https://api.tavily.com/search');
    expect(seen.headers['Authorization'], 'Bearer tvly-test');
    final Map<String, Object?> sent =
        jsonDecode(seen.body) as Map<String, Object?>;
    expect(sent['query'], 'leo messi');
    expect(sent['max_results'], 3);
    expect(sent['include_raw_content'], isTrue);
    expect(sent['search_depth'], 'basic');

    expect(r.ok, isTrue);
    // Tavily 的 content 是短摘要，raw_content 才是正文 —— 映射到我们的字段。
    expect(r.hits.first.snippet, '短摘要');
    expect(r.hits.first.content, '正文');
    expect(r.hits.first.score, 0.81);
    expect(r.hits.first.date, contains('2025'));
  });

  test('search：没结果不是错误', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json('{"results":[]}', 200),
    );
    final SearchOutcome r = await api.search('k', 'q', client: c);
    expect(r.ok, isTrue);
    expect(r.hits, isEmpty);
    expect(r.message, '没有搜到结果');
  });

  test('search：空搜索词不发请求', () async {
    int calls = 0;
    final MockClient c = MockClient((http.Request r) async {
      calls++;
      return json('{"results":[]}', 200);
    });
    final SearchOutcome r = await api.search('k', '   ', client: c);
    expect(r.ok, isFalse);
    expect(calls, 0);
  });

  test('错误码：401 / 432 / 433 都有自己的人话', () async {
    Future<SearchOutcome> withCode(int code) {
      final MockClient c = MockClient(
        (http.Request r) async => json('{"detail":{"error":"boom"}}', code),
      );
      return api.search('k', 'q', client: c);
    }

    expect((await withCode(401)).message, contains('tvly-'));
    expect((await withCode(432)).message, contains('额度'));
    expect((await withCode(433)).message, contains('按量付费'));
    // 厂商原话要带上。
    expect((await withCode(432)).message, contains('boom'));
  });

  test('extract：一次给 urls 数组，拿回 raw_content', () async {
    late http.Request seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r;
      return json(
        '{"results":[{"url":"https://a.example/1","title":"标题","raw_content":"# 正文"}],'
        '"failed_results":[]}',
        200,
      );
    });

    final FetchOutcome r = await api.extract(
      'tvly-test',
      'https://a.example/1',
      client: c,
    );

    expect(seen.url.toString(), 'https://api.tavily.com/extract');
    expect(jsonDecode(seen.body), <String, Object?>{
      'urls': <String>['https://a.example/1'],
    });
    expect(r.ok, isTrue);
    expect(r.title, '标题');
    expect(r.content, contains('正文'));
  });

  test('extract：没结果的把 failed_results 的原因说出来', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json(
        '{"results":[],"failed_results":[{"url":"https://x","error":"404 Not Found"}]}',
        200,
      ),
    );
    final FetchOutcome r = await api.extract('k', 'https://x', client: c);
    expect(r.ok, isFalse);
    expect(r.message, contains('404 Not Found'));
  });

  test('分发：按服务商地址认厂商（用真的 SearchService，不是另写一份）', () {
    SearchVendor v(String base) => SearchService(
      Provider(
        id: 'x',
        protocol: Protocol.openaiCompatible,
        name: 'x',
        baseUrl: base,
      ),
    ).vendor;

    expect(v('https://api.tavily.com'), SearchVendor.tavily);
    expect(v('https://api.deepseek.com'), SearchVendor.deepseek);
    // 没接的厂商不能瞎认。
    expect(v('https://api.exa.ai'), SearchVendor.unknown);
  });
}
