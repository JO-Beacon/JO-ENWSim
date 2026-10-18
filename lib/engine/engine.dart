// 引擎：让世界真的往前走。
//
// 一回合内部的流程（照 `AGENTS/架构.md`）：
//
//   A₀ 是否分裂序列
//    └ 本回合做哪一件？ 环境更新（A₁） 或 角色回合（A₂ → B₁… → A₃ → B₂）
//    └ A₄ 是否合并
//
// **每一步都是一次 LLM 调用**，返回值是结构化的 JSON。
//
// ——— 两件现在没做的，写在明处，不装 ———
//
// 1. **提示词是内置默认**。设置 → 引擎 里那些输入框现在只是输入框：
//    没人保存、也没人读（页面一关就没了）。等那层接上，把 [_prompts] 换成
//    用户填的即可，其余不用动。
// 2. **A₀ 与 A₄ 的判断现在不改变行为**。分裂与合并没有落地的数据表示
//    （`回合数据.md` 末尾列着这两条"还没定"）。引擎会把判断**记下来**
//    （`judgment`），但不会真的裂/并——**如实记录，不假装做过**。
//
// ——— 提示词怎么排（KV 缓存的要求）———
//
// DeepSeek 的缓存命中价差 50 倍，命中要求**前缀逐字节稳定**。所以：
//   稳定的放最前（规则、世界观、角色卡、输出格式）
//   每回合变的放最后（本回合的指令、当前状态）
// 这些提示词就是这么拼的。

import 'dart:convert';
import 'dart:io';

import '../data/world_store.dart';
import '../model/char_choices.dart';
import '../model/demo.dart';
import '../model/llm_client.dart';
import '../model/memory.dart';
import '../model/model_plan.dart';
import '../model/provider.dart';
import '../model/turn.dart';

/// 跑一回合要用的东西。
class EngineInput {
  const EngineInput({
    required this.store,
    required this.provider,
    required this.apiKey,
    required this.world,
    required this.laneId,
    required this.globalPlan,
    this.worldPlan = const ModelPlan(),
    this.charPlans = const <String, ModelPlan>{},
    this.charChoices = const <String, CharChoices>{},
    this.memories = const <MemoryBook>[],
    this.recentSteps = 12,
    this.prompts = const <String, String>{},
    this.onStep,
  });

  final WorldStore store;
  final Provider provider;
  final String apiKey;
  final World world;
  final String laneId;

  /// 模型解析链：角色 → 世界默认 → 全局。
  final ModelPlan globalPlan;
  final ModelPlan worldPlan;
  final Map<String, ModelPlan> charPlans;

  /// 每个角色的“选择”（温度、流式、思考…）。
  final Map<String, CharChoices> charChoices;

  /// 记忆：上帝那本 + 各角色那本。
  final List<MemoryBook> memories;

  /// 提示词里带多少步最近的回合。太少会失忆，太多会撑爆——
  /// 而且缓存前缀会更容易被打断。
  final int recentSteps;

  /// 每**进一个步骤**时喊一声（`A0` / `AD` / `A1` / `A2` / `B1` / `A3` / `B2` / `A4`）。
  ///
  /// 只是报进度，不动任何逻辑：右栏那张流程图靠它高亮当前步。
  /// B₁ 是按角色一个个跑的，IDs 相同，会喊多次。
  /// 每**进一个步骤**时喊一声（`A0` / `AD` / `A1` / `A2` / `B1` / `A3` / `B2` / `A4`）。
  ///
  /// 只是报进度，不动任何逻辑：右栏那张流程图靠它高亮当前步。
  /// B₁ 是按角色一个个跑的，IDs 相同，会喊多次。
  final void Function(String stepId)? onStep;

  /// 每一步的提示词（用户在设置 → 引擎里填的）。
  ///
  /// 缺的用内置默认 —— 但**引擎不再自己闷头用默认**：
  /// 界面上看得见什么，这里就是什么。
  final Map<String, String> prompts;
}

/// 一次调用的结果，加上这一步到底用了什么。
class _Call {
  const _Call({required this.step, required this.usage});

  final TurnStep step;
  final LlmUsage? usage;
}

class Engine {
  Engine(this.input);

  final EngineInput input;

  /// 跑**单步**用的（内部）。
  ///
  /// 界面上那个“单步”不是这个 —— 它跑的是 [runTurn]（一整条流程）。
  /// 这里只是把某一步单独拉出来，给调试和将来的“逐步执行”用。
  Future<TurnStep> run(String stepId) async {
    switch (stepId) {
      case 'A0':
        return _record((await _a0()).step);
      case 'A1':
        return _record((await _a1()).step);
      case 'A2':
        return _record((await _a2()).step);
      case 'AD':
        return _record((await _decide()).step);
      case 'A4':
        return _record((await _a4()).step);
      case 'A3':
        // A₃ 靠 B₁ 的结果才能做，单独跑没有依据。
        //
        // 这里**不抛异常** —— 抛会崩，而“用法不对”该像别的失败一样
        // 如实返回一条带 error 的记录（跟引擎其它错误一个形状）。
        return _record(
          const TurnStep(
            kind: 'A3',
            who: '旁白',
            error: 'A3 要跟 B₁ 一起跑（用 runCharacterTurn）；单独跑它没有依据。',
          ),
        );
      default:
        throw ArgumentError('引擎里没有这一步：$stepId');
    }
  }

  /// 跑**整条角色回合**：A₂ → B₁… → A₃ → B₂。
  ///
  /// 这中间只有 A₂ / A₃ / B₂ 会上序列；B₁ 是过程，结果并进最后那一步。
  Future<List<TurnStep>> runCharacterTurn() async {
    final TurnStep a2 = _record((await _a2()).step);
    final List<String> cast = a2.candidates;
    if (cast.isEmpty) {
      // 没有人参与 —— 如实记一笔，不硬凑。
      return <TurnStep>[a2];
    }

    final Map<String, String> seen = <String, String>{};
    for (final String name in cast) {
      seen[name] = await _b1(name);
    }

    final TurnStep a3 = _record((await _a3(cast, seen)).step);
    final String who = a3.chosen.isEmpty ? cast.first : a3.chosen;

    final _Call b2 = await _b2(who, seen);
    // 过程产物并进最后那一步 —— 这一回合为什么是这个人。
    return <TurnStep>[
      a2,
      a3,
      _record(
        TurnStep(
          kind: b2.step.kind,
          who: b2.step.who,
          time: b2.step.time,
          text: b2.step.text,
          candidates: cast,
          perceptions: seen,
          chosen: who,
          error: b2.step.error,
          model: b2.step.model,
          choices: b2.step.choices,
          usage: b2.usage,
        ),
      ),
    ];
  }

  /// 跑**一次完整流程** —— 界面上那个“单步”就是它。
  ///
  /// A₀ 判断要不要分裂
  ///   → A 决策：这一步做环境更新（A₁）还是角色回合（A₂ → B₁… → A₃ → B₂）
  ///   → A₄ 判断要不要合并
  ///
  /// 注意：“单步”不是“跑某一步”，是**一整条流程**。
  Future<List<TurnStep>> runTurn() async {
    final List<TurnStep> out = <TurnStep>[];

    out.add(_record((await _a0()).step));

    // A 决策走哪一条。这一步不落盘 —— 它是判断，不是行为。
    // A 决策走哪一条。这一步**自己就是一个步骤**（id 'AD'）——
    // 它有自己的模型配置与提示词框，不借别人的名字。
    //
    // 跟 A₀ / A₄ 一样**记进序列**：三者都是判断，没有理由只记两个。
    final TurnStep decided = _record((await _decide()).step);
    out.add(decided);
    final Map<String, Object?>? dj = _asJson(decided.text);
    final String next = '${dj?['next'] ?? ''}'.trim().toLowerCase();

    if (next == 'env') {
      out.add(_record((await _a1()).step));
    } else {
      out.addAll(await runCharacterTurn());
    }

    out.add(_record((await _a4()).step));
    return out;
  }

  // ————————————————————————————— 每一步

  Future<_Call> _a0() async => _ask(
    stepId: 'A0',
    who: '旁白',
    // 分裂判断现在不改变行为，记下来即可。
    want: '{"split": true 或 false, "why": "一句话"}',
    task:
        '看这条序列最近的走向，判断它**要不要裂成两条**。'
        '这一步只做判断，写进 split 与 why。',
  );

  Future<_Call> _a1() async => _ask(
    stepId: 'A1',
    who: '旁白',
    want: '{"time": "时间标签", "text": "发生了什么的正文", "judgment": "一句话"}',
    task:
        '把世界自身的事件（昼夜、天气、火势、人群之类）往前推一步。'
        '不要写任何角色的主动行为——那是角色回合的事。'
        'time 是**文本时间标签**（比如“入夜之后”），不是时间戳。',
  );

  /// A 决策：本回合做环境更新还是角色回合。
  ///
  /// 它**自己就是一个步骤**（id `AD`）——有自己的模型配置与提示词框。
  Future<_Call> _decide() async => _ask(
    stepId: 'AD',
    who: '旁白',
    want: '{"next": "env" 或 "turn", "why": "一句话"}',
    task:
        '判断**本回合该做哪一件**：\n'
        '  env  = 环境更新（推进世界自身的事件：昼夜、天气、火势、人群）\n'
        '  turn = 角色回合（某个角色行动一次）\n'
        '没有外部规则，你自己看当前情势定。把选择写进 next。',
  );

  Future<_Call> _a2() async => _ask(
    stepId: 'A2',
    who: '旁白',
    want: '{"candidates": ["角色名", ...]}',
    task:
        '判断这一步有资格行动的角色，放进 candidates。'
        '只从下面列出的角色里选，名字要**一模一样**。',
  );

  Future<_Call> _a3(List<String> cast, Map<String, String> seen) async => _ask(
    stepId: 'A3',
    who: '旁白',
    want: '{"chosen": "角色名"}',
    task:
        '下面是这一步每个参与角色各自感知到了什么。'
        '据此挑**唯一一个**该行动的角色，放进 chosen。'
        '只能从这些名字里挑：${cast.join('、')}。',
    extra: seen.entries
        .map((MapEntry<String, String> e) => '【${e.key} 感知到】${e.value}')
        .join('\n'),
  );

  Future<_Call> _a4() async => _ask(
    stepId: 'A4',
    who: '旁白',
    // 合并没有落地的数据表示，记下来即可。
    want: '{"merge": true 或 false, "why": "一句话"}',
    task:
        '看这条序列，判断它**要不要和别的序列合并**。'
        '这一步只做判断，写进 merge 与 why。',
  );

  /// B₁：感知。**过程**，不写进序列。
  Future<String> _b1(String name) async {
    final _Call c = await _ask(
      stepId: 'B1',
      who: name,
      focus: name,
      want: '{"perception": "这个角色此刻感知到了什么"}',
      task:
          '写出**$name 此刻感知到了什么**。'
          '只能写这个角色能知道的：看得见、听得见、摸得着的。'
          '不要写它的想法或决定（那是下一步的事），也不要写别人的内心。',
    );
    // B₁ 不落盘（它是过程），所以日志得在这儿补 ——
    // 否则日志里只有四个“→ B1”，看着像全挂了。
    _say(
      '← B1  ${c.step.ok ? 'ok' : '错'}  感知${c.step.text.length}字'
      '${c.step.ok ? '' : '  ${c.step.error}'}',
    );
    if (!c.step.ok) return '（没跑成：${c.step.error}）';
    // `_stepFrom` 已经把 perception 落成 `text` 了 —— 别再当 JSON 解一次。
    // （之前这里从 text 里找 JSON，永远找不到，感知就全空。）
    return c.step.text.trim();
  }

  Future<_Call> _b2(String name, Map<String, String> seen) async => _ask(
    stepId: 'B2',
    who: name,
    focus: name,
    want: '{"time": "时间标签", "text": "这个角色的行为"}',
    task:
        '写出**$name 这一步的行为**。'
        '一行到几句话，写它做了什么、说了什么，不要写别人的反应。'
        'time 是**文本时间标签**，不是时间戳。',
    extra: seen[name] == null ? '' : '【$name 此刻感知到】${seen[name]}',
  );

  // ————————————————————————————— 调用的公共部分

  /// 组一次请求、调一次、解析、落成 [TurnStep]。
  ///
  /// JSON 解析失败会**再问一次**（官方承认会偶发返回空 content，
  /// 这不是可选项）。
  /// 引擎写的一行日志。
  ///
  /// **release 版没有控制台**，print 用户看不到 —— 所以写文件：
  /// `%APPDATA%\JO-Beacon\JO-ENWSim\engine.log`。
  /// 每一步的请求、结果、错误都记一行，不用再盲人摸象。
  static void _say(String line) {
    try {
      final String base = Platform.environment['APPDATA'] ?? '.';
      final Directory dir = Directory('$base\\JO-Beacon\\JO-ENWSim');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File f = File('${dir.path}\\engine.log');
      final String stamp = DateTime.now().toIso8601String().substring(11, 19);
      f.writeAsStringSync(
        '$stamp  $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 写不了算了 —— 不能因为日志把引擎搞挂。
    }
  }

  Future<_Call> _ask({
    required String stepId,
    required String who,
    required String want,
    required String task,
    String focus = '',
    String extra = '',
  }) async {
    // 报进度：所有步骤都从这里过，所以只在这里喊一声就够。
    input.onStep?.call(stepId);

    final String model = _modelFor(stepId, focus);
    // 模型是空的就别发 —— 发出去只会换来一个 400，
    // 而且用户看不出是“没选模型”还是“模型名写错了”。
    if (model.trim().isEmpty) {
      return _Call(
        step: TurnStep(
          kind: stepId,
          who: who,
          error:
              '还没给这一步选模型。\n'
              '去 设置 → 引擎 里配一个（或在世界的“模型”页里配），'
              '填好之后再点“单步”。',
        ),
        usage: null,
      );
    }
    final CharChoices? choices = focus.isEmpty
        ? null
        : input.charChoices[focus];
    final String system = _system(want, focus: focus);
    _say('→ $stepId  model=${_keyOf(model)}  system=${system.length}字');
    // 提示词**从用户填的那份来**。传进来的 task 只是兜底
    // （比如用户把这一步的提示词整个删空了）。
    final String fromUser = (input.prompts[stepId] ?? '').trim();
    final String user = _user(
      task: fromUser.isNotEmpty ? fromUser : task,
      extra: extra,
    );

    LlmReply? last;
    for (int attempt = 0; attempt < 2; attempt++) {
      final LlmReply r = await LlmClient.send(
        input.provider,
        input.apiKey,
        LlmRequest(
          // 发出去的是**模型名**（`deepseek-flash`），不是拼出来的键。
          model: _keyOf(model),
          // system 用**顶层参数**：Anthropic 形状就认这个；OpenAI 形状
          // 会在 `toJson()` 里拼回 messages 的一条，两种形状都不丢。
          system: system,
          messages: <LlmMessage>[LlmMessage('user', user)],
          thinking: choices?.stream == null ? true : null,
          temperature: _num(choices?.temperature),
          topP: _num(choices?.topP),
          maxTokens: _int(choices?.maxOutput),
          jsonMode: true,
          // 内置搜索是**模型服务**上的开关（只有 Anthropic 形状有）。
          webSearch: input.provider.builtinSearch
              ? input.provider.builtinSearchShape
              : BuiltinSearch.none,
        ),
      );
      last = r;
      if (!r.ok) {
        // 调用本身出错（网络 / 余额 / 参数）——重试没用就报出来。
        return _Call(
          step: TurnStep(
            kind: stepId,
            who: who,
            text: '',
            error: r.error,
            model: ModelPick.of(model),
            choices: choices,
          ),
          usage: r.usage,
        );
      }
      if (_asJson(r.text) != null) {
        return _Call(step: _stepFrom(stepId, who, r, choices), usage: r.usage);
      }
      // 空 content 或不是 JSON —— 再问一次。
    }

    return _Call(
      step: TurnStep(
        kind: stepId,
        who: who,
        error:
            '两次都没拿到能解析的 JSON。最后收到的是：'
            '${(last?.text ?? '').trim().isEmpty ? '（空的）' : last!.text}',
        model: ModelPick.of(model),
        choices: choices,
      ),
      usage: last?.usage,
    );
  }

  /// 把返回的 JSON 落成 [TurnStep]。字段按各步的 [want] 来。
  TurnStep _stepFrom(
    String stepId,
    String who,
    LlmReply r,
    CharChoices? choices,
  ) {
    final Map<String, Object?> j = _asJson(r.text) ?? <String, Object?>{};
    String s(String k) => '${j[k] ?? ''}';
    final List<String> cast = j['candidates'] is List
        ? (j['candidates']! as List).whereType<String>().toList()
        : const <String>[];
    return TurnStep(
      kind: stepId,
      who: stepId == 'B1' || stepId == 'B2' ? who : '旁白',
      time: s('time'),
      text: stepId == 'B1' ? s('perception') : s('text'),
      candidates: cast,
      chosen: s('chosen'),
      judgment:
          '${s('why')}${s('judgment')}'
          '${j['split'] != null ? 'split=${j['split']}' : ''}'
          '${j['merge'] != null ? 'merge=${j['merge']}' : ''}',
      model: ModelPick.of(_modelFor(stepId, who)),
      choices: choices,
      usage: r.usage,
    );
  }

  /// 系统提示词。**稳定的部分在这儿**，每回合变的放 [user]。
  /// 系统提示词。**按“各步骤读什么”分视角** —— 架构里那张表。
  ///
  /// 差别全在历史那一段：
  ///   · A 侧（[focus] 为空，全知）：本序列上发生的一切
  ///   · B₁ / B₂（[focus] 是角色名）：**只看本地点**发生的事，
  ///     加上**他自己的记忆**。别的地点做过什么，他看不见。
  ///
  /// 两件要说明的：
  ///   · “环境状态”“序列状态”在架构里有名字，但**还没有独立的数据表示**。
  ///     这里从已有数据里取：它们都是步。A₁ 推的环境也在历史里。
  ///   · 记忆以前传进来了却没用，现在接上了。
  String _system(String want, {String focus = ''}) {
    final bool asChar = focus.isNotEmpty;
    final StringBuffer b = StringBuffer();

    b.writeln(
      asChar
          ? '你在一个涌现叙事世界里，扮演其中的“$focus”。'
                '只写你看见、听见、做到的事；你不知道别人心里在想什么。'
          : '你在一个涌现叙事世界里推动故事。世界按因果自行展开，没有剧本。',
    );
    b.writeln();

    // —— 世界观与开场：角色只知道自己在哪、周围什么样；
    //    世界观是上帝视角的东西，**不给角色**（给了就等于告诉他剧本）。
    if (!asChar) {
      b.writeln('【这个世界】');
      b.writeln(
        input.world.setting.trim().isEmpty
            ? '（还没写世界观）'
            : input.world.setting.trim(),
      );
      b.writeln();
      if (input.world.opening.trim().isNotEmpty) {
        b.writeln('【开场】');
        b.writeln(input.world.opening.trim());
        b.writeln();
      }
    }

    // —— 人物
    if (asChar) {
      final String me =
          input.world.characters
              .where((CharCard c) => c.name == focus)
              .map((CharCard c) => c.persona)
              .firstOrNull ??
          '';
      b.writeln('【你】');
      b.writeln(me.isEmpty ? focus : '$focus：$me');
      b.writeln();
      final List<String> others = input.world.characters
          .where((CharCard c) => c.name != focus)
          .map((CharCard c) => c.name)
          .toList();
      if (others.isNotEmpty) {
        // 只给名字 —— 别人的底细不是他能看到的。
        b.writeln('【这里还有别人】${others.join('、')}');
        b.writeln();
      }
    } else {
      b.writeln('【角色】');
      for (final CharCard c in input.world.characters) {
        b.writeln('- ${c.name}：${c.persona}');
      }
      b.writeln();
    }

    // —— 所在地点
    final SeqLane? lane = input.world.lanes
        .where((SeqLane l) => l.id == input.laneId)
        .firstOrNull;
    if (lane != null) {
      b.writeln('【现在在】${lane.place}');
      b.writeln();
    }

    // —— 历史：**这段是信息隔离的关键**
    final List<TurnStep> steps = input.store.loadSteps(
      input.world.id,
      input.laneId,
    );
    final int from = steps.length > input.recentSteps
        ? steps.length - input.recentSteps
        : 0;
    b.writeln(asChar ? '【你在这条序列上经历的】' : '【这条序列上已发生的事】');
    bool any = false;
    for (int i = from; i < steps.length; i++) {
      final TurnStep s = steps[i];
      if (!s.showsOnCanvas) continue;
      any = true;
      b.writeln('${s.who}（${s.time}）：${s.text}');
      if (asChar) {
        // 轮到他自己那一步时，把他当时的感知也带上——
        // 那是他亲身得到的，别人没有。
        final String? seen = s.perceptions[focus];
        if (seen != null && seen.trim().isNotEmpty) {
          b.writeln('   （你当时感觉：${seen.trim()}）');
        }
      }
    }
    if (!any) b.writeln('（还没有）');
    b.writeln();

    // —— 记忆：角色只有自己那一本；上帝有自己那本。
    final MemoryBook? book = input.memories
        .where((MemoryBook m) => m.ownerId == focus)
        .firstOrNull;
    if (book != null && book.entries.isNotEmpty) {
      b.writeln(asChar ? '【你记得的】' : '【记录】');
      for (final MemoryEntry m in book.entries) {
        b.writeln('- ${m.content}');
      }
      b.writeln();
    }

    b.writeln('【输出格式】');
    b.writeln('只输出一个 JSON 对象，不要有任何别的文字、不要用代码块包起来。');
    b.writeln('要的字段：$want');
    return b.toString();
  }

  /// 用户提示词。**每回合变的部分在这儿**（放最后）。
  String _user({required String task, String extra = ''}) {
    final StringBuffer b = StringBuffer();
    b.writeln('【这一步要做的】');
    b.writeln(task);
    if (extra.isNotEmpty) {
      b.writeln();
      b.writeln(extra);
    }
    b.writeln();
    b.writeln('只输出 JSON。');
    return b.toString();
  }

  // ————————————————————————————— 模型与工具

  /// 解析这一步用哪个模型：角色自己的 → 世界默认 → 全局默认。
  String _modelFor(String stepId, String focus) {
    final ModelPlan? cp = focus.isEmpty ? null : input.charPlans[focus];
    final String own = cp?.stepKey(stepId) ?? '';
    if (own.isNotEmpty) return own;
    final String charDefault = cp?.defaultRef ?? '';
    if (charDefault.isNotEmpty) return charDefault;
    final String w = input.worldPlan.stepKey(stepId);
    if (w.isNotEmpty) return w;
    final String wd = input.worldPlan.defaultRef;
    if (wd.isNotEmpty) return wd;
    final String g = input.globalPlan.stepKey(stepId);
    if (g.isNotEmpty) return g;
    return input.globalPlan.defaultRef;
  }

  /// [ModelPick.key]（`服务商id\u0000模型id`）→ 真正发给 API 的模型名。
  ///
  /// 一开始这里直接返回了整个键 —— 那是拼出来的标识，不是模型名，
  /// 发出去会被服务端拒掉。
  String _keyOf(String modelKey) => ModelPick.of(modelKey)?.modelId ?? modelKey;

  String _rawOf(_Call c) => c.step.text.startsWith('{') ? c.step.text : '{}';

  Map<String, Object?>? _asJson(String text) {
    final String t = text.trim();
    if (t.isEmpty) return null;
    try {
      final Object? j = jsonDecode(t);
      return j is Map ? j.cast<String, Object?>() : null;
    } catch (_) {
      // 有的模型爱包一层代码块。剥一次再试。
      final int a = t.indexOf('{');
      final int b = t.lastIndexOf('}');
      if (a < 0 || b <= a) return null;
      try {
        final Object? j = jsonDecode(t.substring(a, b + 1));
        return j is Map ? j.cast<String, Object?>() : null;
      } catch (_) {
        return null;
      }
    }
  }

  double? _num(String? s) =>
      s == null || s.trim().isEmpty ? null : double.tryParse(s.trim());

  int? _int(String? s) =>
      s == null || s.trim().isEmpty ? null : int.tryParse(s.trim());

  /// 落盘。B₁ 是过程，不占序列上的一步，所以不写。
  TurnStep _record(TurnStep s) {
    // **每一步都存** —— 判断也是。你说过“留”。
    // 画布只显示行为（showsOnCanvas），那是显示的事，不该管存不存。
    input.store.appendStep(input.world.id, input.laneId, s);
    _say(
      '← ${s.kind}  ${s.ok ? 'ok' : '错'}  正文${s.text.length}字'
      '${s.candidates.isEmpty ? '' : '  参与${s.candidates.length}人'}'
      '${s.chosen.isEmpty ? '' : '  选中${s.chosen}'}'
      '${s.judgment.isEmpty ? '' : '  判定${s.judgment.length}字'}'
      '${s.usage == null ? '' : '  入${s.usage!.input}/出${s.usage!.output}/命中${s.usage!.cacheHit}'}'
      '${s.ok ? '' : '  ${s.error}'}',
    );
    return s;
  }
}
