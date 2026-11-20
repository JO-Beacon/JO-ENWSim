import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/tts/kokoro_voices.dart';

void main() {
  test('Kokoro v1.1 有 103 个声线，sid 0–102 不重复', () {
    expect(kKokoroVoices, hasLength(103));
    expect(kKokoroVoices.map((KokoroVoice v) => v.sid).toSet(), <int>{
      for (int i = 0; i < 103; i++) i,
    });
  });

  test('0–2 英文女声，3–57 中文女声，58–102 中文男声', () {
    expect(
      kKokoroVoices.where(
        (KokoroVoice v) => v.language == KokoroLanguage.english,
      ),
      hasLength(3),
    );
    expect(
      kKokoroVoices.where(
        (KokoroVoice v) => v.language == KokoroLanguage.chinese && v.female,
      ),
      hasLength(55),
    );
    expect(
      kKokoroVoices.where(
        (KokoroVoice v) => v.language == KokoroLanguage.chinese && !v.female,
      ),
      hasLength(45),
    );
    for (final KokoroVoice v in kKokoroVoices) {
      if (v.sid <= 2) {
        expect(v.language, KokoroLanguage.english);
        expect(v.female, isTrue);
      } else if (v.sid <= 57) {
        expect(v.language, KokoroLanguage.chinese);
        expect(v.female, isTrue);
      } else {
        expect(v.language, KokoroLanguage.chinese);
        expect(v.female, isFalse);
      }
    }
  });

  test('试听文本按声线语言切换', () {
    expect(KokoroLanguage.english.sample, contains('Hello'));
    expect(KokoroLanguage.chinese.sample, contains('你好'));
    expect(kokoroVoiceOf(0)?.name, 'af_maple');
    expect(kokoroVoiceOf(3)?.name, 'zf_001');
    expect(kokoroVoiceOf(47)?.name, 'zf_083');
    expect(kokoroVoiceOf(58)?.name, 'zm_009');
    expect(kokoroVoiceOf(102)?.name, 'zm_100');
    expect(kokoroVoiceOf(0)?.language, KokoroLanguage.english);
    expect(kokoroVoiceOf(47)?.language, KokoroLanguage.chinese);
    expect(kokoroVoiceOf(103), isNull);
  });
}
