// 服务商接口的两件事：**测连通**和**拉模型**。
//
// 规矩（这次专门拆开）：
//   · `probe` = 只回答“通不通、key 对不对”，**不返回模型列表**，不动配置；
//   · `fetchModels` = 拉列表（调用方会写回配置），那是“获取模型”。
//
// 用 MockClient，不发真请求。

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/model/provider_api.dart';

http.Response json(String body, int code) => http.Response(
  body,
  code,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

void main() {
  const Provider openai = Provider(
    id: 'p1',
    protocol: Protocol.openai,
    name: 'OpenAI',
    apiKey: 'sk-test',
    baseUrl: 'https://api.openai.com/v1',
  );

  const Provider deepseek = Provider(
    id: 'p2',
    protocol: Protocol.deepseek,
    name: 'DeepSeek',
    apiKey: 'sk-test',
    baseUrl: 'https://api.deepseek.com',
  );

  test('probe：200 就算通了，但不把模型列表吐出来', () async {
    late Uri seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r.url;
      return json('{"data":[{"id":"gpt-x"},{"id":"gpt-y"}]}', 200);
    });

    final ProbeResult r = await ProviderApi.probe(openai, client: c);

    expect(seen.toString(), 'https://api.openai.com/v1/models');
    expect(r.ok, isTrue);
    expect(r.message, contains('连上了'));
    // 关键：测试不返回模型，免得调用方顺手写回配置。
    expect(r.models, isEmpty);
  });

  test('probe：401 说 key 不对', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json('{"error":{"message":"bad key"}}', 401),
    );
    final ProbeResult r = await ProviderApi.probe(openai, client: c);
    expect(r.ok, isFalse);
    expect(r.message, contains('API Key 不对'));
  });

  test('probe：DeepSeek 走余额接口，不是模型列表', () async {
    late Uri seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r.url;
      return json(
        '{"is_available":true,"balance_infos":['
        '{"currency":"CNY","total_balance":"12.34",'
        '"granted_balance":"0.00","topped_up_balance":"12.34"}]}',
        200,
      );
    });

    final ProbeResult r = await ProviderApi.probe(deepseek, client: c);
    expect(seen.toString(), 'https://api.deepseek.com/user/balance');
    expect(r.ok, isTrue);
    expect(r.message, contains('余额'));
    expect(r.models, isEmpty);
  });

  test('fetchModels：这个才拉列表', () async {
    final MockClient c = MockClient(
      (http.Request r) async =>
          json('{"data":[{"id":"gpt-x"},{"id":"gpt-y"}]}', 200),
    );
    final ProbeResult r = await ProviderApi.fetchModels(openai, client: c);
    expect(r.ok, isTrue);
    expect(r.models, <String>['gpt-x', 'gpt-y']);
  });
}
