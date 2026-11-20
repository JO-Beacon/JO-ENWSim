// 网络设置（代理）的运行时入口。
//
// `http` 包默认的 Client 不会读环境变量里的代理；这里统一建 IOClient，
// 需要时给 HttpClient 装 findProxy。所有内置 HTTP 客户端都走 newClient()，
// 设置页改代理后下一次请求生效。

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class NetworkRuntime {
  NetworkRuntime._();

  static bool proxyEnabled = false;
  static String proxyHost = '127.0.0.1';
  static int proxyPort = 7890;

  static void configure({
    required bool proxyEnabled,
    required String proxyHost,
    required int proxyPort,
  }) {
    NetworkRuntime.proxyEnabled = proxyEnabled;
    NetworkRuntime.proxyHost = proxyHost.trim();
    NetworkRuntime.proxyPort = proxyPort;
  }

  static http.Client newClient() {
    final HttpClient client = HttpClient();
    if (proxyEnabled && proxyHost.isNotEmpty) {
      client.findProxy = (Uri uri) => 'PROXY $proxyHost:$proxyPort';
    }
    return IOClient(client);
  }
}
