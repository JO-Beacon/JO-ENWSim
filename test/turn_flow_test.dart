// 右栏那张“回合流程”图。
//
// 收起时只占一行，展开后整张图随右栏滚动。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/step_id.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/turn_flow.dart';

Widget host(Widget child) => MaterialApp(
  home: JoTheme(
    settings: const JoSettings(),
    palette: JoPalette.dark,
    child: Scaffold(body: child),
  ),
);

final Finder diagram = find.byKey(const ValueKey<String>('flow-diagram'));

void main() {
  test('每个正式步骤恰好一个块，角色、批次和裁定后缀复用原块', () {
    final ids = <String>{
      for (final step in kAiSteps) step.id,
      'SYS_SCHEDULE', StepId.sysRecord, StepId.sysCommit, StepId.sysRecovery,
    };
    expect(FlowStep.values.map((step) => step.id), unorderedEquals(ids));
    for (final id in ids) {
      expect(flowStepOf(id)?.id, id);
    }
    expect(flowStepOf('CH_PERCEIVE:慧音:env'), FlowStep.perceive);
    expect(flowStepOf('GM_OBSERVE_SCENE:env'), FlowStep.observeScene);
    expect(flowStepOf('CH_MEMORY_WRITE:角色'), FlowStep.writeMemory);
    expect(flowStepOf('CH_MEMORY_RECALL:角色'), FlowStep.recall);
    expect(flowStepOf('GM_RESOLVE_ACTION:contest'), FlowStep.resolve);
    expect(flowStepOf(null), isNull);
    expect(flowStepOf('XX'), isNull);
  });

  test('按回合类型交付见闻、处理玩家输入、裁定与重写', () {
    final edges = {for (final edge in turnFlowEdges) (edge.from, edge.to)};
    void expectPath(List<FlowStep> steps) {
      for (int i = 1; i < steps.length; i++) {
        expect(edges, contains((steps[i - 1], steps[i])));
      }
    }
    expectPath([FlowStep.route, FlowStep.observeScene, FlowStep.perceive, FlowStep.writeMemory,
      FlowStep.cast, FlowStep.eligibility, FlowStep.selectActor, FlowStep.recall, FlowStep.act,
      FlowStep.record, FlowStep.mergePlace, FlowStep.commit, FlowStep.narrate, FlowStep.review]);
    expectPath([FlowStep.eligibility, FlowStep.environment, FlowStep.record, FlowStep.observeScene,
      FlowStep.perceive, FlowStep.writeMemory, FlowStep.mergePlace]);
    expectPath([FlowStep.route, FlowStep.environment, FlowStep.schedule]);
    expectPath([FlowStep.recall, FlowStep.parseInput, FlowStep.act, FlowStep.resolve, FlowStep.record]);
    expectPath([FlowStep.resolve, FlowStep.commit]);
    expectPath([FlowStep.review, FlowStep.narrate]);
  });

  test('步骤块互不重叠，箭头只接触块的边缘', () {
    final bounds = Offset.zero & turnFlowSize;
    for (final step in FlowStep.values) {
      expect(bounds.intersect(step.rect), step.rect);
      for (final other in FlowStep.values.where((other) => other != step)) {
        expect(step.rect.overlaps(other.rect), isFalse, reason: '${step.id} / ${other.id}');
      }
    }
    for (final edge in turnFlowEdges) {
      final points = edge.points;
      for (int i = 1; i < points.length; i++) {
        final start = points[i - 1];
        final end = points[i];
        expect(start, isNot(end));
        expect(start.dx == end.dx || start.dy == end.dy, isTrue);
        final segment = Rect.fromPoints(start, end).inflate(0.1);
        for (final step in FlowStep.values) {
          expect(segment.overlaps(step.rect.deflate(0.5)), isFalse,
              reason: '${edge.from.id} 到 ${edge.to.id} 的连线穿过了 ${step.id}');
        }
      }
    }
  });

  testWidgets('收起时只占一行：有标题和“展开”，没有图', (WidgetTester t) async {
    await t.pumpWidget(
      host(TurnFlow(palette: JoPalette.dark, onToggle: () {})),
    );

    expect(t.takeException(), isNull);
    expect(find.text('回合流程'), findsOneWidget);
    expect(find.text('展开'), findsOneWidget);
    expect(diagram, findsNothing);
  });

  testWidgets('收起时也看得到当前跑到哪一步', (WidgetTester t) async {
    await t.pumpWidget(
      host(TurnFlow(palette: JoPalette.dark, active: 'CH_PERCEIVE', onToggle: () {})),
    );
    expect(find.textContaining('当前：'), findsOneWidget);
    expect(find.textContaining(FlowStep.perceive.title), findsOneWidget);
  });

  testWidgets('点标题能展开、再点能收起', (WidgetTester t) async {
    bool open = false;
    await t.pumpWidget(
      StatefulBuilder(
        builder: (BuildContext c, void Function(void Function()) setState) {
          return host(
            SingleChildScrollView(
              child: TurnFlow(
                palette: JoPalette.dark,
                expanded: open,
                onToggle: () => setState(() => open = !open),
              ),
            ),
          );
        },
      ),
    );

    expect(diagram, findsNothing);
    await t.tap(find.text('回合流程'));
    await t.pumpAndSettle();
    // 展开后：标题在、图也在，且给的是“收起”。
    expect(diagram, findsOneWidget);
    expect(find.text('收起'), findsOneWidget);

    await t.tap(find.text('回合流程'));
    await t.pumpAndSettle();
    expect(diagram, findsNothing);
    expect(find.text('展开'), findsOneWidget);
  });

  testWidgets('展开时图按自己的比例占高度，不被压扁', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        SingleChildScrollView(
          child: TurnFlow(
            palette: JoPalette.dark,
            expanded: true,
            active: 'GM_SELECT_ACTOR',
            done: const <String>{'GM_OPEN_PLACE', 'GM_ROUTE', 'GM_ELIGIBILITY', 'CH_PERCEIVE'},
            onToggle: () {},
          ),
        ),
      ),
    );

    expect(t.takeException(), isNull);
    final Size s = t.getSize(diagram);
    expect(s.aspectRatio, closeTo(turnFlowSize.aspectRatio, 0.01));
    // 图比一屏高——所以它不靠“缩到一屏内”，而是靠外层一起滚。
    expect(s.height, greaterThan(700 * 0.5));
  });

  testWidgets('展开是“顺下去”，不是盖住下面的内容', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        SingleChildScrollView(
          child: Column(
            children: <Widget>[
              TurnFlow(
                palette: JoPalette.dark,
                expanded: true,
                onToggle: () {},
              ),
              // 详情：展开后应该被顶到下面，而不是消失。
              const SizedBox(height: 200, child: Text('世界观')),
            ],
          ),
        ),
      ),
    );

    expect(t.takeException(), isNull);
    expect(diagram, findsOneWidget);
    expect(find.text('世界观'), findsOneWidget);
    // 详情确实在图的下方：滚下去能看见。
    await t.drag(find.byType(SingleChildScrollView), const Offset(0, -900));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('展开是渐进的，不是一下跳出来', (WidgetTester t) async {
    bool open = false;
    await t.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext c, void Function(void Function()) setState) {
            return SingleChildScrollView(
              child: TurnFlow(
                palette: JoPalette.dark,
                expanded: open,
                onToggle: () => setState(() => open = !open),
              ),
            );
          },
        ),
      ),
    );

    final double collapsed = t.getSize(find.byType(TurnFlow)).height;
    await t.tap(find.text('回合流程'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    final double mid = t.getSize(find.byType(TurnFlow)).height;
    await t.pumpAndSettle();
    final double full = t.getSize(find.byType(TurnFlow)).height;

    // 中间那一帧：比收起高、又还没到最终高度 —— 确实在动。
    expect(mid, greaterThan(collapsed));
    expect(mid, lessThan(full));
    // 动画跑完就是整张图的高度（图本身没被压扁）。
    expect(full, greaterThan(collapsed + 300));
  });

  testWidgets('每一步当 active 都不炸（含跑过的那些）', (WidgetTester t) async {
    for (final step in FlowStep.values) {
      final String id = step.id;
      await t.pumpWidget(
        host(
          SingleChildScrollView(
            child: TurnFlow(
              palette: JoPalette.dark,
              expanded: true,
              active: id,
              done: <String>{'GM_OPEN_PLACE', 'GM_ROUTE', id},
              onToggle: () {},
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull, reason: 'active=$id 时抛了');
      expect(find.text(step.title), findsOneWidget);
      expect(find.text('当前：$id · ${step.title}'), findsOneWidget);
    }
  });

  testWidgets('步骤块的底色跟着调色板走，不再写死一套亮色', (WidgetTester t) async {
    Color fillOf(String title) {
      final DecoratedBox box = t.widget<DecoratedBox>(
        find
            .ancestor(of: find.text(title), matching: find.byType(DecoratedBox))
            .first,
      );
      return (box.decoration as BoxDecoration).color!;
    }

    for (final (JoPalette palette, bool dark) in <(JoPalette, bool)>[
      (JoPalette.dark, true),
      (JoPalette.light, false),
    ]) {
      await t.pumpWidget(
        host(
          SingleChildScrollView(
            child: TurnFlow(palette: palette, expanded: true, onToggle: () {}),
          ),
        ),
      );
      final double gm = fillOf('选择回合路线').computeLuminance();
      final double act = fillOf('提出角色行动').computeLuminance();
      // 写死亮色的老实现，在暗色下这两块都会是 0.8 以上的亮度。
      expect(gm < 0.2, dark, reason: '${palette.isDark} 下程序步骤的底色亮度是 $gm');
      expect(act < 0.2, dark, reason: '${palette.isDark} 下角色行动的底色亮度是 $act');
      expect((act - gm).abs(), greaterThan(0.02), reason: '行动块和程序块看不出轻重');
    }
  });
}
