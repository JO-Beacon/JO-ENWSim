// 界面语言。
//
// 按国际标准来：**BCP 47 语言标签**（`zh-Hans-CN` 这种）+
// 语言用它自己的名字、地区放在括号里。
//
// 注意：现在只是**列表**——选了还不会换界面文字（i18n 是独立的一件事）。

/// 一条语言：标签 + 显示名。
typedef JoLanguage = ({String tag, String label});

/// 语言表。按语言自己的名字排，和平台的做法一致。
const List<JoLanguage> kJoLanguages = <JoLanguage>[
  (tag: 'zh-Hans-CN', label: '中文（中国）'),
  (tag: 'zh-Hant-TW', label: '中文（中国台湾）'),
  (tag: 'zh-Hant-HK', label: '中文（中国香港）'),
  (tag: 'en-US', label: 'English (United States)'),
  (tag: 'en-GB', label: 'English (United Kingdom)'),
  (tag: 'ja-JP', label: '日本語（日本）'),
  (tag: 'ko-KR', label: '한국어（대한민국）'),
  (tag: 'de-DE', label: 'Deutsch (Deutschland)'),
  (tag: 'fr-FR', label: 'Français (France)'),
  (tag: 'es-ES', label: 'Español (España)'),
  (tag: 'pt-BR', label: 'Português (Brasil)'),
  (tag: 'ru-RU', label: 'Русский (Россия)'),
  (tag: 'it-IT', label: 'Italiano (Italia)'),
  (tag: 'pl-PL', label: 'Polski (Polska)'),
  (tag: 'tr-TR', label: 'Türkçe (Türkiye)'),
  (tag: 'vi-VN', label: 'Tiếng Việt (Việt Nam)'),
  (tag: 'th-TH', label: 'ไทย (ประเทศไทย)'),
  (tag: 'id-ID', label: 'Bahasa Indonesia (Indonesia)'),
  (tag: 'ar-SA', label: 'العربية (المملكة العربية السعودية)'),
  (tag: 'hi-IN', label: 'हिन्दी (भारत)'),
];

/// 现在只做好了中文（中国）。
const String kJoLangDefault = 'zh-Hans-CN';
