/// 世界级独立搜索源。
///
/// 只存在世界里，不按回合开关。这里只列由 App 调用的 SearchService；
/// 模型自带搜索属于模型服务商能力，不在这个枚举里。
enum WorldSearchSource {
  off('off', '不搜索', '不使用 Tavily / DeepSeek 独立搜索；模型自带搜索仍由模型服务商控制。'),
  tavily('tavily', 'Tavily', '程序调用 Tavily 的搜索接口。'),
  deepseek('deepseek', 'DeepSeek 搜索', '程序调用 DeepSeek 的 Search / Fetch 接口。');

  const WorldSearchSource(this.id, this.label, this.hint);

  final String id;
  final String label;
  final String hint;

  static WorldSearchSource byId(String? id) {
    for (final WorldSearchSource s in values) {
      if (s.id == id) return s;
    }
    return WorldSearchSource.off;
  }
}
