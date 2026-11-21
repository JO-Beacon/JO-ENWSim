import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/player_input.dart';
import 'package:joenws/engine/sequence.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

const Provider _provider = Provider(
  id: 'p-test',
  protocol: Protocol.deepseekAnthropic,
  name: 'test',
  // 声明能力才收图：没填就当没有（这条规矩在 llm_vision_test 里钉着）。
  models: <ModelRef>[
    ModelRef(id: 'test-model', caps: ModelCaps(vision: true)),
  ],
);

LlmAgentRunner _runner(Future<LlmReply> Function(LlmRequest) sender) {
  return LlmAgentRunner(
    provider: _provider,
    apiKey: 'test-key',
    model: 'test-model',
    sender: sender,
  );
}

NarrativeScene _pScene() {
  return NarrativeScene(
    place: '东门内侧',
    names: <String, String>{
      'char:信标': '信标',
      'char:艾琳': '艾琳',
    },
    cast: <CharacterSnapshot>[
      CharacterSnapshot(
        id: 'char:信标',
        name: '信标',
        nearby: true,
        aliases: <String, String>{'char:艾琳': '联邦女人'},
      ),
      CharacterSnapshot(
        id: 'char:艾琳',
        name: '艾琳',
        nearby: true,
        aliases: <String, String>{'char:信标': '探险家'},
      ),
    ],
  );
}

void main() {
  test('perceive 解析 percepts', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      expect(req.system, contains('感知'));
      return const LlmReply(
        text:
            '{"percepts":[{"event_id":"E1","content":"我听见了。"}],"attention":"想回应。"}',
      );
    });
    final Map<String, Object?> out = await runner.perceive(
      name: '灵梦',
      context: '【灵梦】',
      events: 'E1 信标说：你好。',
    );
    expect(out['attention'], '想回应。');
    expect((out['percepts'] as List).length, 1);
  });

  test('CH_MEMORY_WRITE write 解析记忆操作', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text:
            '{"operations":[{"op":"encode","kind":"episodic","text":"我看见了。",'
            '"source_events":["evt-1"]}]}',
      );
    });
    final List<MemoryOperation>? ops = await runner.manageMemory(
      characterId: 'char:灵梦',
      percepts: const <String, Object?>{
        'percepts': <Object?>[
          <String, Object?>{'event_id': 'evt-1', 'content': '信标进来。'},
        ],
      },
      memory: const <CharacterMemory>[],
      allowedEventIds: const <String>{'evt-1'},
    );
    expect(ops, hasLength(1));
    expect(ops!.single.op, 'encode');
  });

  test('CH_MEMORY_WRITE recall 只返回合法记忆 id', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(text: '{"memory_ids":["cm-1"]}');
    });
    final List<String>? ids = await runner.recallMemory(
      characterId: 'char:灵梦',
      scene: _pScene(),
      percepts: const <String, Object?>{},
      memory: const <CharacterMemory>[
        CharacterMemory(
          id: 'cm-1',
          characterId: 'char:灵梦',
          text: '我记得。',
        ),
      ],
    );
    expect(ids, <String>['cm-1']);
  });

  test('render 解析 public_text', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text: '{"public_text":"灵梦看了过来。","god_note":""}',
      );
    });
    final Map<String, Object?> out = await runner.render(
      events: const <WorldEvent>[],
    );
    expect(out['public_text'], '灵梦看了过来。');
  });

  test('带代码块的 JSON 也能解析', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text: '```json\n{"intent_id":"i1","actor":"char:灵梦","text":"我想看看门外"}\n```',
      );
    });
    final intent = await runner.intend(
      actor: '灵梦',
      delivered: '',
      recalled: '',
      present: <String>['灵梦'],
    );
    expect(intent.text, '我想看看门外');
  });

  test('非 JSON 输出会重试，第二次成功', () async {
    int calls = 0;
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      calls++;
      return LlmReply(
        text: calls == 1
            ? '不是 JSON'
            : '{"percepts":[],"attention":"重试成功"}',
      );
    });
    final Map<String, Object?> out = await runner.perceive(
      name: '灵梦',
      context: '',
      events: '',
    );
    expect(calls, 2);
    expect(out['attention'], '重试成功');
  });

  test('GM_ROUTE 可以请求玩家帮助，回答会进入下一次请求', () async {
    int calls = 0;
    String? seenUser;
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      calls++;
      if (calls == 1) {
        return const LlmReply(
          text:
              '{"ask_player":true,"code":"need_route","question":"走哪条？",'
              '"options":["env","turn"],"kind":"choice","reason":"测试"}',
        );
      }
      seenUser = req.messages.first.content;
      return const LlmReply(text: '{"next":"env","why":"按回答"}');
    });
    try {
      await runner.decideNext(
        scene: _pScene(),
        events: const <WorldEvent>[],
      );
      fail('应该抛出 AskPlayerException');
    } on AskPlayerException catch (error) {
      expect(error.request.step, 'GM_ROUTE');
      expect(error.request.question, '走哪条？');
      expect(error.request.options, <String>['env', 'turn']);
    }
    runner.setPlayerHelp(<String, String>{'GM_ROUTE': 'env'});
    final String route = await runner.decideNext(
      scene: _pScene(),
      events: const <WorldEvent>[],
    );
    expect(calls, 2);
    expect(route, 'env');
    expect(seenUser, contains('玩家刚才的回答'));
  });

  test('LLM 报错时抛 LlmAgentException', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(error: '余额不足');
    });
    await expectLater(
      runner.perceive(
        name: '灵梦',
        context: '',
        events: '',
      ),
      throwsA(isA<LlmAgentException>()),
    );
  });

  test('parsePlayer 解析 segments 并保留 audience 未决', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      expect(req.system, contains('玩家输入理解器'));
      return const LlmReply(
        text:
            '{"segments":['
            '{"id":"s1","kind":"action","text":"看向艾琳","target":"艾琳","delivery":{"channel":"visual","form":"gesture","audience":"scene"},"delivery_note":null,"distance_note":null,"manner":null,"manner_note":null,"evidence":{"kind":"看向艾琳","target":"看向艾琳","delivery":"无/未声明","manner":"无/未声明"}},'
            '{"id":"s2","kind":"speech","text":"“你没事吧？”","target":"艾琳","delivery":{"channel":"voice","form":"spoken","audience":"unknown"},"delivery_note":"声音小了一些","distance_note":"因为距离近","manner":null,"manner_note":null,"evidence":{"kind":"“你没事吧？”","target":"看向艾琳","delivery":"声音小了一些","manner":"无/未声明"}}'
            '],"unresolved":[{"segment_ids":["s2"],"field":"delivery.audience","question":"只让艾琳听见，还是附近/全场也能听见？","why":"原文只说声音小了一些。","options":["target","nearby","scene"]}],"warnings":[]}',
      );
    });
    final PlayerParseResult r = await runner.parsePlayer(
      raw: '我看向艾琳，因为距离近，所以声音小了一些，“你没事吧？”',
      scene: _pScene(),
      playerName: '信标',
    );
    expect(r.segments.length, 2);
    expect(r.needsConfirmation, isTrue);
    expect(r.audienceQuestions.length, 1);
    expect(r.segments[1].delivery.audience, Audience.unknown);
    expect(r.segments[1].deliveryNote, '声音小了一些');
    expect(r.segments[1].distanceNote, '因为距离近');
  });

  test('parsePlayer 解析 state_delta 和行动类型', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text:
            '{"segments":[{"id":"s1","kind":"action","text":"走到门口","target":null,'
            '"delivery":{"channel":"visual","form":"gesture","audience":"scene"},'
            '"delivery_note":null,"distance_note":null,"manner":null,"manner_note":null,'
            '"action_kind":null,"evidence":{"kind":"走到门口"}}],'
            '"state_delta":{"move":{"信标":"门口"}},'
            '"state_delta_evidence":{"move.信标":"走到门口"},'
            '"unresolved":[],"warnings":[]}',
      );
    });
    final PlayerParseResult r = await runner.parsePlayer(
      raw: '我走到门口',
      scene: _pScene(),
      playerName: '信标',
    );
    expect(r.stateDelta['move'], <String, String>{'信标': '门口'});
    expect(r.stateDeltaEvidence['move.信标'], '走到门口');
  });

  test('parsePlayer 用背包上下文校验 items 的规范 id', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      expect(
        req.messages.map((LlmMessage m) => m.content).join('\n'),
        contains('item:key'),
      );
      return const LlmReply(
        text:
            '{"segments":[{"id":"s1","kind":"action","text":"捡起钥匙","target":null,'
            '"delivery":{"channel":"visual","form":"gesture","audience":"scene"},'
            '"delivery_note":null,"distance_note":null,"manner":null,"manner_note":null,'
            '"action_kind":null,"requires":[],"evidence":{"kind":"捡起钥匙"}}],'
            '"state_delta":{"items":[{"kind":"take","item_id":"item:key",'
            '"from":"place:门厅","to":"信标"}]},'
            '"state_delta_evidence":{"items.0":"捡起钥匙"},"unresolved":[],"warnings":[]}',
      );
    });
    final PlayerParseResult r = await runner.parsePlayer(
      raw: '我捡起钥匙',
      scene: _pScene(),
      playerName: '信标',
      context: const PlayerInputContext(
        inventory: <Map<String, String>>[
          <String, String>{'id': 'item:key', 'name': '钥匙'},
        ],
      ),
    );
    expect(r.stateDelta['items'], isNotEmpty);
    expect(r.segments.single.requires, isEmpty);
  });

  test('parsePlayer 对背包和现场都没有的物品 id 返回未决问题', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text:
            '{"segments":[{"id":"s1","kind":"action","text":"捡起钥匙","target":null,'
            '"delivery":{"channel":"visual","form":"gesture","audience":"scene"},'
            '"delivery_note":null,"distance_note":null,"manner":null,"manner_note":null,'
            '"action_kind":null,"requires":[],"evidence":{"kind":"捡起钥匙"}}],'
            '"state_delta":{"items":[{"kind":"take","item_id":"item:unknown",'
            '"from":"place:门厅","to":"信标"}]},'
            '"state_delta_evidence":{"items.0":"捡起钥匙"},"unresolved":[],"warnings":[]}',
      );
    });
    final PlayerParseResult r = await runner.parsePlayer(
      raw: '我捡起钥匙',
      scene: _pScene(),
      playerName: '信标',
      maxAttempts: 1,
    );
    expect(r.unresolved.single.field, 'state_delta.items.0');
    expect(r.unresolved.single.options, isEmpty);
  });

  test('parsePlayer 的 text 不是原文子串时抛错', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text:
            '{"segments":[{"id":"s1","kind":"action","text":"改写过的句子","target":null,"delivery":{"channel":"visual","form":"gesture","audience":"scene"},"delivery_note":null,"distance_note":null,"manner":null,"manner_note":null,"evidence":{}}],"unresolved":[],"warnings":[]}',
      );
    });
    await expectLater(
      runner.parsePlayer(
        raw: '我看向艾琳。',
        scene: _pScene(),
        playerName: '信标',
      ),
      throwsA(isA<LlmAgentException>()),
    );
  });

  test('parsePlayer 不合格会回给 GM_PARSE_INPUT 重写', () async {
    int calls = 0;
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      calls++;
      if (calls == 1) {
        return const LlmReply(
          text:
              '{"segments":[{"id":"s1","kind":"action","text":"改写过的句子","target":null,"delivery":{"channel":"visual","form":"gesture","audience":"scene"},"delivery_note":null,"distance_note":null,"manner":null,"manner_note":null,"evidence":{}}],"unresolved":[],"warnings":[]}',
        );
      }
      return const LlmReply(
        text:
            '{"segments":[{"id":"s1","kind":"action","text":"看向艾琳","target":null,"delivery":{"channel":"visual","form":"gesture","audience":"scene"},"delivery_note":null,"distance_note":null,"manner":null,"manner_note":null,"evidence":{}}],"unresolved":[],"warnings":[]}',
      );
    });
    final PlayerParseResult r = await runner.parsePlayer(
      raw: '我看向艾琳。',
      scene: _pScene(),
      playerName: '信标',
    );
    expect(calls, 2);
    expect(r.segments.single.text, '看向艾琳');
  });

  test('逐步骤模型和提示词覆盖进请求', () async {
    const Provider alt = Provider(
      id: 'alt',
      protocol: Protocol.openai,
      name: 'alt',
      apiKey: 'alt-key',
      models: <ModelRef>[ModelRef(id: 'alt-model')],
    );
    String? seenModel;
    String? seenUser;
    final LlmAgentRunner runner = LlmAgentRunner(
      provider: _provider,
      apiKey: 'test-key',
      model: 'fallback-model',
      modelResolver: (String step, {String focus = ''}) {
        if (step == 'GM_OPEN_PLACE') {
          return (provider: alt, model: 'alt-model');
        }
        return null;
      },
      prompts: <String, String>{'GM_OPEN_PLACE': 'CUSTOM GM_OPEN_PLACE TASK'},
      sender: (LlmRequest req) async {
        seenModel = req.model;
        seenUser = req.messages.first.content;
        return const LlmReply(text: '{"places":[],"why":"ok"}');
      },
    );
    await runner.decideOpenParallelPlace(scene: _pScene(), events: <WorldEvent>[]);
    expect(seenModel, 'alt-model');
    expect(seenUser, contains('CUSTOM GM_OPEN_PLACE TASK'));
  });

  test('CH_PERCEIVE 把角色 focus 和提示词覆盖传给请求', () async {
    String? seenStep;
    String? seenFocus;
    String? seenUser;
    final LlmAgentRunner runner = LlmAgentRunner(
      provider: _provider,
      apiKey: 'test-key',
      model: 'fallback-model',
      modelResolver: (String step, {String focus = ''}) {
        seenStep = step;
        seenFocus = focus;
        return null;
      },
      prompts: <String, String>{'CH_PERCEIVE': 'CUSTOM CH_PERCEIVE TASK'},
      sender: (LlmRequest req) async {
        seenUser = req.messages.first.content;
        return const LlmReply(
          text: '{"percepts":[],"attention":"听见了。"}',
        );
      },
    );
    await runner.perceive(
      name: '灵梦',
      context: '【灵梦】',
      events: 'E1 信标说：你好。',
    );
    expect(seenStep, 'CH_PERCEIVE');
    expect(seenFocus, '灵梦');
    expect(seenUser, contains('CUSTOM CH_PERCEIVE TASK'));
  });

  test('GM_OPEN_PLACE/GM_ENV_UPDATE/GM_MERGE_PLACE/GM_REVIEW_NARRATION 都能解析', () async {    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      final String system = req.system ?? '';
      if (system.contains('GM_OPEN_PLACE')) {
        return const LlmReply(text: '{"places":[],"why":"单序列"}');
      }
      if (system.contains('GM_ENV_UPDATE')) {
        return const LlmReply(
          text:
              '{"events":[{"content":"雨小了。","target":null,"delivery":{"channel":"other","form":"narration","audience":"scene"}}]}',
        );
      }
      if (system.contains('GM_MERGE_PLACE')) {
        return const LlmReply(text: '{"merge":false,"why":"不需要"}');
      }
      return const LlmReply(text: '{"violations":["有一句像心理"]}');
    });

    final List<WorldEvent> events = <WorldEvent>[
      WorldEvent(
        id: 'E1',
        kind: WorldEventKind.speech,
        content: '你好。',
        actor: 'char:信标',
        target: 'char:艾琳',
        delivery: const Delivery(
          channel: DeliveryChannel.voice,
          form: 'spoken',
          audience: Audience.scene,
        ),
      ),
    ];
    expect((await runner.decideOpenParallelPlace(scene: _pScene(), events: events)).openParallelPlace,
        isFalse);
    final List<WorldEvent> env =
        await runner.environmentEvents(scene: _pScene(), events: events);
    expect(env.single.content, '雨小了。');
    expect((await runner.decideMerge(scene: _pScene(), events: events)).merge,
        isFalse);
    expect(await runner.checkRender(
      publicText: '正文',
      godNote: '',
      events: events,
    ), <String>['有一句像心理']);
  });

  test('GM_ENV_UPDATE 会把外部搜索材料放进提示词', () async {
    String seen = '';
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      seen = req.messages.isEmpty ? '' : req.messages.last.content;
      return const LlmReply(text: '{"events":[]}');
    });
    await runner.environmentEvents(
      scene: _pScene(),
      events: <WorldEvent>[],
      searchMaterial: '查询：沈宅落款\n标题：沈宅档案',
    );
    expect(seen, contains('外部搜索材料'));
    expect(seen, contains('沈宅落款'));
  });

  test('GM_OPEN_PLACE/GM_MERGE_PLACE 带 place / into 能解析，且序列上下文进提示词', () async {
    String seen = '';
    final LlmAgentRunner runner = LlmAgentRunner(
      provider: _provider,
      apiKey: 'test-key',
      model: 'test-model',
      parallelPlaces: const <ParallelPlaceInfo>[
        ParallelPlaceInfo(id: 'l1', place: '正厅', members: <String>['信标']),
        ParallelPlaceInfo(id: 'l2', place: '仓房', members: <String>['艾琳']),
      ],
      parallelPlaceCandidates: const <ParallelPlaceCandidate>[
        ParallelPlaceCandidate(place: '仓房', members: <String>['艾琳']),
      ],
      currentParallelPlaceId: 'l1',
      sender: (LlmRequest req) async {
        final String system = req.system ?? '';
        if (system.contains('GM_OPEN_PLACE')) {
          seen = req.messages.isEmpty ? '' : req.messages.last.content;
          return const LlmReply(
            text: '{"places":[{"place":"仓房","why":"切过去"},'
                '{"place":"后巷","why":"火势蔓延"}]}',
          );
        }
        if (system.contains('GM_MERGE_PLACE')) {
          seen = req.messages.isEmpty ? '' : req.messages.last.content;
          return const LlmReply(
            text: '{"merge":true,"into":"l2","why":"并过去"}',
          );
        }
        return const LlmReply(text: '{}');
      },
    );

    final OpenPlaceResult openPlace = await runner.decideOpenParallelPlace(
      scene: _pScene(),
      events: const <WorldEvent>[],
    );
    expect(openPlace.openParallelPlace, isTrue);
    expect(openPlace.place, '仓房');
    expect(openPlace.openings.length, 2);
    expect(openPlace.openings.last.place, '后巷');
    expect(seen, contains('l2｜仓房'));
    expect(seen, contains('待开启并行地点'));

    final MergePlaceResult mergePlace = await runner.decideMerge(
      scene: _pScene(),
      events: const <WorldEvent>[],
    );
    expect(mergePlace.merge, isTrue);
    expect(mergePlace.into, 'l2');
    expect(seen, contains('其他未合并序列'));
  });

  test('parsePlayer 把文本 / PDF 附件内容放进输入', () async {
    late LlmRequest seen;
    final LlmAgentRunner runner = LlmAgentRunner(
      provider: _provider,
      apiKey: 'test-key',
      model: 'test-model',
      loadAttachmentText: (String id) async =>
          id == 'a1' ? '信上写着：今夜不要出门。' : null,
      sender: (LlmRequest req) async {
        seen = req;
        return const LlmReply(
          text:
              '{"segments":[{"id":"s1","kind":"action","text":"我读信",'
              '"target":null,"delivery":{"channel":"visual","form":"gesture",'
              '"audience":"scene"},"delivery_note":null,"distance_note":null,'
              '"manner":null,"manner_note":null,"evidence":{}}],'
              '"unresolved":[],"warnings":[]}',
        );
      },
    );
    await runner.parsePlayer(
      raw: '我读信。',
      scene: _pScene(),
      playerName: '信标',
      attachmentIds: const <String>['a1'],
    );
    expect(seen.messages.single.content, contains('信上写着'));
  });

  test('CH_PERCEIVE 图片：perceiveWithImages 把附件读成图片塞进请求', () async {
    late LlmRequest seen;
    final LlmAgentRunner runner = LlmAgentRunner(
      provider: _provider,
      apiKey: 'test-key',
      model: 'test-model',
      loadImage: (String id) async =>
          id == 'a1' ? const LlmImage(bytes: <int>[1, 2, 3], mime: 'image/png') : null,
      sender: (LlmRequest req) async {
        seen = req;
        return const LlmReply(
          text: '{"percepts":[],"attention":"看到了。"}',
        );
      },
    );
    await runner.perceiveWithImages(
      name: '灵梦',
      context: '【灵梦】',
      events: 'E1 信标拿起一个苹果。',
      imageAssetIds: const <String>['a1'],
    );
    expect(seen.messages.single.images.single.mime, 'image/png');
    expect(seen.messages.single.images.single.bytes, <int>[1, 2, 3]);
  });
}
