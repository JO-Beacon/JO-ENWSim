import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider.dart';

/// 探测结果（测试连接 / 获取模型共用）。
class ProbeResult {
  const ProbeResult({
    required this.ok,
    required this.message,
    this.models = const <String>[],
  });

  final bool ok;
  final String message;
  final List<String> models;
}

/// 跟服务商说话：拉模型列表、查余额。
class ProviderApi {
  static const Duration _timeout = Duration(seconds: 20);

  /// 查余额（目前只有 DeepSeek 有公开的余额接口）。
  static Future<ProbeResult> fetchBalance(Provider p) async {
    if (!p.protocol.isDeepSeek) {
      return const ProbeResult(ok: false, message: '这个服务商没有余额接口');
    }
    final String base = _accountBase(p);
    final Uri? uri =
        base.isEmpty ? null : Uri.tryParse('$base/user/balance');
    if (uri == null) {
      return const ProbeResult(ok: false, message: '接口地址填得不对');
    }
    try {
      final http.Response r =
          await http.get(uri, headers: _headers(p)).timeout(_timeout);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return ProbeResult(ok: false, message: _httpMessage(r.statusCode, r.body));
      }
      return ProbeResult(ok: true, message: _parseBalance(r.body));
    } catch (e) {
      return ProbeResult(ok: false, message: '请求失败：$e');
    }
  }

  /// 拉模型列表。成功 = 连上了。
  static Future<ProbeResult> fetchModels(Provider p) async {
    if (p.protocol.listPath == null) {
      return ProbeResult(
        ok: false,
        message: '${p.protocol.label}这个协议没有模型列表接口',
      );
    }
    final Uri? uri = _modelsUri(p);
    if (uri == null) {
      return const ProbeResult(ok: false, message: '接口地址填得不对');
    }
    try {
      final http.Response r = await http
          .get(uri, headers: _headers(p))
          .timeout(_timeout);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return ProbeResult(
          ok: false,
          message: _httpMessage(r.statusCode, r.body,
              deepSeek: p.protocol.isDeepSeek),
        );
      }
      final List<String> ids = _parseIds(p.protocol, r.body);
      if (ids.isEmpty) {
        return ProbeResult(
          ok: false,
          message: '连上了，但没解析出模型：${_short(r.body)}',
        );
      }
      return ProbeResult(
        ok: true,
        message: '连上了 · ${ids.length} 个模型',
        models: ids,
      );
    } catch (e) {
      return ProbeResult(ok: false, message: '请求失败：$e');
    }
  }

  /// 账号级接口（模型列表 / 余额）挂在主域名上。
  ///
  /// DeepSeek 的 Anthropic 格式是在路径后面加 /anthropic，
  /// 但它的 /models、/user/balance 在主域名上——**不能**把 /models
  /// 直接接在 /anthropic 后面。所以这里要把那个后缀剥掉。
  static String _accountBase(Provider p) {
    final String base = p.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    const String suffix = '/anthropic';
    if (p.protocol.isDeepSeek && base.endsWith(suffix)) {
      return base.substring(0, base.length - suffix.length);
    }
    return base;
  }

  static Uri? _modelsUri(Provider p) {
    final String base = _accountBase(p);
    final String? path = p.protocol.listPath;
    if (base.isEmpty || path == null) return null;
    if (p.protocol.wire == Wire.google) {
      final String key = Uri.encodeQueryComponent(p.apiKey.trim());
      return Uri.tryParse('$base$path?key=$key');
    }
    return Uri.tryParse('$base$path');
  }

  static Map<String, String> _headers(Provider p) {
    final Map<String, String> h = <String, String>{
      'Accept': 'application/json',
    };
    final String key = p.apiKey.trim();
    switch (p.protocol.wire) {
      case Wire.openai:
        h['Authorization'] = 'Bearer $key';
      case Wire.anthropic:
        h['x-api-key'] = key;
        h['anthropic-version'] = '2023-06-01';
      case Wire.google:
        break; // key 走 query
    }
    return h;
  }

  static List<String> _parseIds(Protocol proto, String body) {
    final Object? j = jsonDecode(body);
    if (j is! Map) return const <String>[];
    if (proto.wire == Wire.google) {
      final Object? list = j['models'];
      if (list is! List) return const <String>[];
      return list.whereType<Map>().map((Map<dynamic, dynamic> m) {
        final String s = '${m['name'] ?? ''}';
        return s.startsWith('models/') ? s.substring(7) : s;
      }).where((String s) => s.isNotEmpty).toList();
    }
    final Object? list = j['data'];
    if (list is! List) return const <String>[];
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) => '${m['id'] ?? ''}')
        .where((String s) => s.isNotEmpty)
        .toList();
  }

  /// 余额：把官方返回的几档拼成人话。
  static String _parseBalance(String body) {
    final Object? j = jsonDecode(body);
    if (j is! Map) return _short(body);
    final Object? list = j['balance_infos'];
    if (list is! List || list.isEmpty) return _short(body);
    final List<String> parts = <String>[
      for (final Object? e in list)
        if (e is Map)
          '${e['total_balance'] ?? '?'} ${e['currency'] ?? ''}'
              '（赠金 ${e['granted_balance'] ?? '0'} / 充值 ${e['topped_up_balance'] ?? '0'}）',
    ];
    final bool ok = j['is_available'] != false;
    return '${ok ? '余额充足' : '余额不足'} · ${parts.join('　')}';
  }

  /// 错误码先翻译成人话，再附上原文。
  ///
  /// **按厂商分**：402“余额不足”是 DeepSeek 的说法，OpenAI 那边没这一条
  /// （它是 403）；所以别拿一份表套所有厂商。
  static String _httpMessage(int code, String body, {bool deepSeek = false}) {
    final String hint = <int, String>{
          400: '请求格式不对',
          401: 'API Key 不对',
          403: '没有权限',
          404: '地址或模型不存在',
          if (deepSeek) 402: '余额不足，去充值',
          422: '参数不合法',
          429: '请求太快，限流了',
          500: '服务端出错',
          503: '服务端过载',
        }[code] ??
        '请求失败';
    return 'HTTP $code · $hint：${_short(body)}';
  }

  static String _short(String s) {
    final String t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '（空的响应）';
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }
}
