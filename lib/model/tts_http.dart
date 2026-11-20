// TTS 的 HTTP 重试：429 / 5xx / 网络错误重试，其余原样返回。
//
// 只做很薄的一层：不重试 4xx（除了 429），不吞错误，重试次数和等待
// 都可以在测试里调小。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class TtsHttp {
  /// 最多尝试几次（含第一次）。
  static int maxAttempts = 3;

  /// 第 attempt 次失败后的基础等待；测试里可以设成零。
  static Duration retryDelay(int attempt) =>
      Duration(milliseconds: 250 * (1 << attempt));

  static Future<http.Response> postJson({
    required http.Client client,
    required Uri uri,
    required Map<String, String> headers,
    required Object? body,
    required Duration timeout,
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final http.Response r = await client
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(timeout);
        if (!_retryable(r.statusCode) || attempt == maxAttempts - 1) {
          return r;
        }
        await Future<void>.delayed(_waitAfter(r, attempt));
      } catch (e) {
        lastError = e;
        if (attempt == maxAttempts - 1) rethrow;
        await Future<void>.delayed(retryDelay(attempt));
      }
    }
    throw lastError ?? StateError('TTS 请求失败');
  }

  static bool _retryable(int status) =>
      status == 429 || (status >= 500 && status <= 599);

  static Duration _waitAfter(http.Response r, int attempt) {
    final String? raw = r.headers['retry-after'];
    final int? seconds = int.tryParse((raw ?? '').trim());
    if (seconds != null && seconds > 0) {
      // 别让服务端给一个离谱的等待把界面卡死。
      return Duration(seconds: seconds.clamp(1, 10));
    }
    return retryDelay(attempt);
  }
}
