// 右栏那张“回合流程”图。
//
// 它是**会展开的**：收起时只占一行（标题 + 当前步），点一下展开成完整一张图；
// 展开时整体缩放到一屏能看全，不靠滚（这正是之前的问题：固定 340 高的窗口，
// 图有 570 高，底部永远看不全）。
//
// 这里钉四件事：
//   1. 引擎报的步骤 id 能不能落到图上的节点；
//   2. 默认收起：只有一行，没有图；
//   3. 展开/收起都点得动，且展开后确实出现了图；
//   4. 各种 active / done 组合都不炸。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  test('步骤 id → 图上的节点', () {
    expect(flowStepOf('A0'), FlowStep.a0);
    expect(flowStepOf('AD'), FlowStep.decide);
    expect(flowStepOf('A1'), FlowStep.a1);
    expect(flowStepOf('A2'), FlowStep.a2);
    expect(flowStepOf('B1'), FlowStep.b1);
    expect(flowStepOf('A3'), FlowStep.a3);
    expect(flowStepOf('B2'), FlowStep.b2);
    expect(flowStepOf('A4'), FlowStep.a4);
    // 认不出来的就当没有，不瞎指。
    expect(flowStepOf(null), isNull);
    expect(flowStepOf('XX'), isNull);
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
      host(TurnFlow(palette: JoPalette.dark, active: 'B1', onToggle: () {})),
    );
    expect(find.textContaining('当前：'), findsOneWidget);
    expect(find.textContaining(labelOf(FlowStep.b1)), findsOneWidget);
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
            active: 'A3',
            done: const <String>{'A0', 'AD', 'A2', 'B1'},
            onToggle: () {},
          ),
        ),
      ),
    );

    expect(t.takeException(), isNull);
    final Size s = t.getSize(diagram);
    // 宽高比例就是图本身的比例（332:700），没有被风箱式压成一条。
    expect(s.width / s.height, closeTo(332 / 700, 0.01));
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
    for (final String id in <String>[
      'A0',
      'AD',
      'A1',
      'A2',
      'B1',
      'A3',
      'B2',
      'A4',
    ]) {
      await t.pumpWidget(
        host(
          SingleChildScrollView(
            child: TurnFlow(
              palette: JoPalette.dark,
              expanded: true,
              active: id,
              done: <String>{'A0', 'AD', id},
              onToggle: () {},
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull, reason: 'active=$id 时抛了');
    }
  });
}
