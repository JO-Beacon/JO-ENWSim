// 搜索服务的分发：按服务商挑一个能发的实现。
//
//   · DeepSeek：`POST /v1/tools/search`、`/v1/tools/fetch`
//   · Tavily：  `POST /search`、`/extract`
//
// 结果类型两种都一样（`search_types.dart`），上层不用关心是哪家。
//
// 注意：内置搜索（Anthropic 的 `web_search`）**不在这里** —— 那是模型服务的能力，
// 走 `llm_client.dart`。

import 'package:http/http.dart' as http;

import 'deepseek_search.dart';
import 'provider.dart';
import 'search_types.dart';
import 'tavily_search.dart';

export 'search_types.dart';

/// 按服务商挑实现。
///
/// 认不出来就**如实说没接**，别拿别人的请求形状硬发。
class SearchService {
  const SearchService(this.provider);

  final Provider provider;

  /// 这位是按哪种形状发。
  SearchVendor get vendor {
    final String base =
        (provider.baseUrl.trim().isEmpty
                ? provider.protocol.baseUrl
                : provider.baseUrl.trim())
            .toLowerCase();
    if (base.contains('deepseek') || provider.protocol.isDeepSeek) {
      return SearchVendor.deepseek;
    }
    if (base.contains('tavily')) return SearchVendor.tavily;
    return SearchVendor.unknown;
  }

  String get _base {
    final String b = provider.baseUrl.trim().isEmpty
        ? provider.protocol.baseUrl
        : provider.baseUrl.trim();
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  Future<SearchOutcome> search(
    String query, {
    int count = 5,
    bool needContent = false,
    http.Client? client,
  }) {
    switch (vendor) {
      case SearchVendor.deepseek:
        return DeepSeekSearch(base: _base).search(
          provider.apiKey,
          query,
          count: count,
          needContent: needContent,
          client: client,
        );
      case SearchVendor.tavily:
        return TavilySearch(base: _base).search(
          provider.apiKey,
          query,
          count: count,
          needContent: needContent,
          client: client,
        );
      case SearchVendor.unknown:
        return Future<SearchOutcome>.value(
          const SearchOutcome(ok: false, message: '这家搜索接口还没接：只知道地址，不知道请求形状。'),
        );
    }
  }

  Future<FetchOutcome> fetch(String url, {http.Client? client}) {
    switch (vendor) {
      case SearchVendor.deepseek:
        return DeepSeekSearch(
          base: _base,
        ).fetch(provider.apiKey, url, client: client);
      case SearchVendor.tavily:
        return TavilySearch(
          base: _base,
        ).extract(provider.apiKey, url, client: client);
      case SearchVendor.unknown:
        return Future<FetchOutcome>.value(
          const FetchOutcome(ok: false, message: '这家搜索接口还没接。'),
        );
    }
  }
}

enum SearchVendor { deepseek, tavily, unknown }
