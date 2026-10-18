// 右栏那张“回合流程”图。
//
// 图是 `CustomPaint` 画的（菱形判断 / 方框动作 / 分组框 / 带标签的箭头），
// 所以这里钉两件事：
//   1. 引擎报的步骤 id 能不能正确落到图上的节点；
//   2. 组件在各种 active / done 组合下都能建出来，不抛异常。

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

  testWidgets('没有在跑的时候也能建出来', (WidgetTester t) async {
    await t.pumpWidget(host(const TurnFlow(palette: JoPalette.dark)));
    expect(t.takeException(), isNull);
    expect(find.text('回合流程'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
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
          TurnFlow(
            palette: JoPalette.dark,
            active: id,
            done: <String>{'A0', 'AD', id},
          ),
        ),
      );
      expect(t.takeException(), isNull, reason: 'active=$id 时抛了');
    }
  });
}
