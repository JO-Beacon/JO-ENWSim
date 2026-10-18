// DeepSeek Search / Fetch 客户端。
//
// 用 MockClient 打出真实请求体去对：字段名、鉴权头、错误码翻译、响应解析。
// 不发真请求 —— 这个接口**按成功次数收费**，测试里不该花钱。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/deepseek_search.dart';

void main() {
  const DeepSeekSearch api = DeepSeekSearch();

  test('search：请求体与鉴权头照文档', () async {
    late http.Request seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r;
      return http.Response(
        jsonEncode(<String, Object?>{
          'results': <Object?>[
            <String, Object?>{
              'rerank_score': 2.4,
              'title': 'DeepSeek V4 released',
              'url': 'https://example.com/a',
              'snippet': '短摘要',
              'summary': '长摘要',
              'content': '',
              'site_name': 'Example',
              'site_icon': null,
              'date': '2026-06-01T00:00:00+00:00',
              'authority': 3,
            },
          ],
        }),
        200,
        // 真实服务器会带 charset；不带的话 http 包按 latin1 解，中文会乱码。
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    });

    final SearchOutcome r = await api.search(
      'sk-test',
      '  DeepSeek V4  ',
      count: 5,
      client: c,
    );

    expect(seen.url.toString(), 'https://api.deepseek.com/v1/tools/search');
    expect(seen.headers['Authorization'], 'Bearer sk-test');
    expect(seen.headers['Content-Type'], contains('application/json'));
    final Map<String, Object?> sent =
        jsonDecode(seen.body) as Map<String, Object?>;
    expect(sent['query'], 'DeepSeek V4'); // 前后空格被去掉
    expect(sent['count'], 5);
    expect(sent['need_content'], isFalse);

    expect(r.ok, isTrue, reason: r.message);
    expect(r.hits, hasLength(1));
    expect(r.hits.first.title, 'DeepSeek V4 released');
    expect(r.hits.first.authority, 3);
    expect(r.hits.first.score, 2.4);
  });

  test('search：count 超出 1–50 会被夹住', () async {
    late Map<String, Object?> sent;
    final MockClient c = MockClient((http.Request r) async {
      sent = jsonDecode(r.body) as Map<String, Object?>;
      return http.Response('{"results":[]}', 200);
    });

    await api.search('k', 'q', count: 999, client: c);
    expect(sent['count'], 50);
  });

  test('search：搜不到不是错误（空数组照常成功）', () async {
    final MockClient c = MockClient(
      (http.Request r) async => http.Response('{"results":[]}', 200),
    );
    final SearchOutcome r = await api.search('k', 'q', client: c);
    expect(r.ok, isTrue);
    expect(r.hits, isEmpty);
    expect(r.message, '没有搜到结果');
  });

  test('search：空搜索词直接返回失败，不发请求', () async {
    int calls = 0;
    final MockClient c = MockClient((http.Request r) async {
      calls++;
      return http.Response('{"results":[]}', 200);
    });
    final SearchOutcome r = await api.search('k', '   ', client: c);
    expect(r.ok, isFalse);
    expect(calls, 0);
  });

  test('错误码：402 说余额不足、429 说太快、404 说取不到内容', () async {
    Future<SearchOutcome> withCode(int code) {
      final MockClient c = MockClient(
        (http.Request r) async => http.Response(
          '{"error":{"message":"nope","type":"invalid_request_error","param":null,"code":"x"}}',
          code,
        ),
      );
      return api.search('k', 'q', client: c);
    }

    expect((await withCode(402)).message, contains('余额不足'));
    expect((await withCode(429)).message, contains('太快'));
    expect((await withCode(404)).message, contains('取不到可用内容'));
    // 厂商原话要带上，别自己编。
    expect((await withCode(402)).message, contains('nope'));
  });

  test('fetch：请求体只有 url，正文按 Markdown 拿回来', () async {
    late http.Request seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r;
      return http.Response(
        jsonEncode(<String, Object?>{
          'title': 'Example article',
          'content': '# 标题\n\n正文',
        }),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    });

    final FetchOutcome r = await api.fetch(
      'sk-test',
      'https://example.com/a',
      client: c,
    );

    expect(seen.url.toString(), 'https://api.deepseek.com/v1/tools/fetch');
    expect(jsonDecode(seen.body), <String, Object?>{
      'url': 'https://example.com/a',
    });
    expect(r.ok, isTrue, reason: r.message);
    expect(r.title, 'Example article');
    expect(r.content, contains('正文'));
  });

  test('fetch：空地址不发请求', () async {
    int calls = 0;
    final MockClient c = MockClient((http.Request r) async {
      calls++;
      return http.Response('{}', 200);
    });
    final FetchOutcome r = await api.fetch('k', '  ', client: c);
    expect(r.ok, isFalse);
    expect(calls, 0);
  });
}
