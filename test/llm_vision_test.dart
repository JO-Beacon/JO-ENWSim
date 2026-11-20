// 模型不收图时怎么办。
//
// DeepSeek 的 `deepseek-v4-pro` 只收文本：给它发图，服务端**不报错**，
// 而是把图静默替换成 `[Unsupported Image]`。那是最坏的情况——模型以为自己
// 看见了，其实什么都没看到。
//
// 所以这里的规矩是：
//   · 收图的模型：图照发；
//   · 不收图的模型：不发图，先拿这家**收图**的模型把图转成文字，
//     转述和原图一起存着（第一次真需要时才转、才存），以后直接取；
//   · 连转述都做不了：明确说“图没送到”，不许装看见。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

const Provider _provider = Provider(
  id: 'p',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  apiKey: 'sk',
  models: kDeepSeekModels,
);

/// 声明了“只收文本”、但这家里**没有**任何收图的模型：转述也做不了。
const Provider _bare = Provider(
  id: 'b',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  apiKey: 'sk',
  models: <ModelRef>[
    ModelRef(id: 'deepseek-v4-pro', caps: ModelCaps(vision: false)),
  ],
);

/// 模型在列表里，但**一点能力都没填**：一律当没有。
const Provider _noCaps = Provider(
  id: 'nc',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  apiKey: 'sk',
  models: <ModelRef>[ModelRef(id: 'deepseek-v4-pro')],
);

const LlmImage _one = LlmImage(bytes: <int>[1, 2, 3], mime: 'image/png');

const String _saw = '画面里有一把生锈的长剑，斜靠在木架子上。';

/// 跑一次“带图的感知”，把发出去的请求捞回来。
///
/// 返回内容不合 schema 时引擎会重试甚至抛错，这里不关心——
/// 只要请求发出去了就够看出图有没有被带上。
Future<void> _perceive(
  LlmAgentRunner r,
) async {
  try {
    await r.perceiveWithImages(
      name: '魔理沙',
      context: '在场',
      events: '玩家贴了一张图',
      imageAssetIds: <String>['a1'],
    );
  } catch (_) {
    // 忽略：这里只验证请求长什么样。
  }
}

void main() {
  test('不收图的模型：先转述，转述进提示、图不发', () async {
    LlmRequest? captionReq;
    LlmRequest? mainReq;
    String? saved;

    final LlmAgentRunner r = LlmAgentRunner(
      provider: _provider,
      apiKey: 'sk',
      model: 'deepseek-v4-pro',
      sender: (LlmRequest req) async {
        if (req.model == 'deepseek-flash') {
          captionReq = req;
          return const LlmReply(text: _saw);
        }
        mainReq ??= req;
        return const LlmReply(text: '{"perception":"看到了"}');
      },
      loadImage: (String id) async => _one,
      writeImageCaption: (String id, String text) => saved = '$id::$text',
    );
    await _perceive(r);

    // 转述那一次：用的是收图的模型，且带上了图。
    expect(captionReq, isNotNull);
    expect(captionReq!.model, 'deepseek-flash');
    expect(captionReq!.messages.single.images, hasLength(1));
    // 正式那一次：不带图，但带着转述。
    expect(mainReq!.messages.single.images, isEmpty);
    expect(mainReq!.messages.single.content, contains('图片转述'));
    expect(mainReq!.messages.single.content, contains(_saw));
    // 转述和原图并存：按附件 id 存下来了。
    expect(saved, 'a1::$_saw');
  });

  test('已经转述过：直接用存好的，不再调模型', () async {
    LlmRequest? captionReq;
    LlmRequest? mainReq;

    final LlmAgentRunner r = LlmAgentRunner(
      provider: _provider,
      apiKey: 'sk',
      model: 'deepseek-v4-pro',
      sender: (LlmRequest req) async {
        if (req.model == 'deepseek-flash') {
          captionReq = req;
          return const LlmReply(text: _saw);
        }
        mainReq ??= req;
        return const LlmReply(text: '{"perception":"看到了"}');
      },
      loadImage: (String id) async => _one,
      readImageCaption: (String id) => id == 'a1' ? '早就存好的描述' : null,
    );
    await _perceive(r);

    expect(captionReq, isNull, reason: '有缓存就不该再调识图模型');
    expect(mainReq!.messages.single.content, contains('早就存好的描述'));
  });

  test('连转述都做不了：明说图没送到，不许装看见', () async {
    LlmRequest? mainReq;

    final LlmAgentRunner r = LlmAgentRunner(
      provider: _bare,
      apiKey: 'sk',
      model: 'deepseek-v4-pro',
      sender: (LlmRequest req) async {
        mainReq ??= req;
        return const LlmReply(text: '{"perception":"看到了"}');
      },
      loadImage: (String id) async => _one,
    );
    await _perceive(r);

    expect(mainReq!.messages.single.images, isEmpty);
    expect(mainReq!.messages.single.content, contains('图片没能传给模型'));
  });

  test('没填能力就当没有：图不发，也不转述', () async {
    LlmRequest? mainReq;

    final LlmAgentRunner r = LlmAgentRunner(
      provider: _noCaps,
      apiKey: 'sk',
      model: 'deepseek-v4-pro',
      sender: (LlmRequest req) async {
        mainReq ??= req;
        return const LlmReply(text: '{"perception":"看到了"}');
      },
      loadImage: (String id) async => _one,
    );
    await _perceive(r);

    expect(mainReq!.messages.single.images, isEmpty);
    expect(mainReq!.messages.single.content, contains('图片没能传给模型'));
  });

  test('收图的模型：图照发，不加那些话', () async {
    LlmRequest? mainReq;

    final LlmAgentRunner r = LlmAgentRunner(
      provider: _provider,
      apiKey: 'sk',
      model: 'deepseek-flash',
      sender: (LlmRequest req) async {
        mainReq ??= req;
        return const LlmReply(text: '{"perception":"看到了"}');
      },
      loadImage: (String id) async => _one,
    );
    await _perceive(r);

    expect(mainReq!.messages.single.images, hasLength(1));
    expect(mainReq!.messages.single.content, isNot(contains('图片')));
  });
}
