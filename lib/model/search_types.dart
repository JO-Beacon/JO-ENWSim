// 搜索结果的共用类型。
//
// 各厂商的请求/响应长得不一样（DeepSeek 与 Tavily 差得不少），但对上层
// ——界面、引擎——只该有一副样子：`SearchHit` / `SearchOutcome`。
// 具体怎么发请求，各在各的文件里（`deepseek_search.dart`、`tavily_search.dart`），
// 由 `search_api.dart` 按服务商分发。

/// 一条搜索结果。
class SearchHit {
  const SearchHit({
    required this.title,
    required this.url,
    this.snippet = '',
    this.summary = '',
    this.content = '',
    this.siteName,
    this.date,
    this.authority,
    this.score,
  });

  final String title;
  final String url;

  /// 一两百字，给界面看的。
  final String snippet;

  /// 六到八百字，给模型读的。
  final String summary;

  /// 正文（要了才有，否则空）。
  final String content;

  final String? siteName;
  final String? date;

  /// 权威档位 0–4（-1 = 未知）。只有 DeepSeek 有。
  final int? authority;

  /// 相关度。两个厂商都有，但量纲不同（DeepSeek 0–3，Tavily 0–1）。
  final double? score;
}

/// 一次搜索的结果。
class SearchOutcome {
  const SearchOutcome({
    required this.ok,
    required this.message,
    this.hits = const <SearchHit>[],
  });

  final bool ok;
  final String message;
  final List<SearchHit> hits;
}

/// 取回一页正文的结果。
class FetchOutcome {
  const FetchOutcome({
    required this.ok,
    required this.message,
    this.title = '',
    this.content = '',
  });

  final bool ok;
  final String message;
  final String title;
  final String content;
}
