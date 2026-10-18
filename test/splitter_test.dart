// 栏间拖动条。
//
// 重点不是“能拖”，而是拖得像样：
//   1. 往哪个方向变宽（左栏 / 右栏方向相反）；
//   2. **不粘手**：宽度只能是“按下位置到鼠标现在的位置”算出来的，
//      所以撞到上限再拖回来，边的位置跟鼠标对得上；
//      以前是逐帧加增量，撞上限后往回拖会整段错位；
//   3. 有边界（min/max）、双击复位、栏宽存盘。
//
// 注：拖动识别有阈值，拿起手势后的那一段位移会被识别器吃掉，
// 所以断言都用“从开始拖的那一刻算起”的相对位移。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/splitter.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget host(Widget child) => MaterialApp(
  home: JoTheme(
    settings: const JoSettings(),
    palette: JoPalette.dark,
    child: Scaffold(
      body: Row(
        children: <Widget>[
          child,
          const Expanded(child: SizedBox.expand()),
        ],
      ),
    ),
  ),
);

/// 造一个把宽度记在 State 里的拖动条，返回一个能读当前宽度的壳。
class Rig {
  Rig(this.build, this.width, this.savedOf);

  final Widget Function() build;
  final double Function() width;
  final double? Function() savedOf;
}

Rig rig({
  double initial = 200,
  bool growsRight = true,
  double min = 100,
  double max = 400,
  double def = 220,
}) {
  double w = initial;
  double? saved;
  Widget build() => host(
    StatefulBuilder(
      builder: (BuildContext c, void Function(void Function()) setState) {
        return JoSplitter(
          palette: JoPalette.dark,
          width: w,
          minWidth: min,
          maxWidth: max,
          defaultWidth: def,
          growsRight: growsRight,
          onResize: (double v) => setState(() => w = v),
          onResizeEnd: () => saved = w,
        );
      },
    ),
  );
  return Rig(build, () => w, () => saved);
}

/// 按住拖动条，先越过识别阈值，再交给调用方继续拖。
Future<TestGesture> grab(WidgetTester t, {double dir = 1}) async {
  final TestGesture g = await t.startGesture(
    t.getCenter(find.byType(JoSplitter)),
    kind: PointerDeviceKind.mouse,
  );
  await t.pump();
  await g.moveBy(Offset(40 * dir, 0));
  await t.pump();
  return g;
}

double widthOf(WidgetTester t) =>
    t.widget<JoSplitter>(find.byType(JoSplitter)).width;

/// 松手后等一等：双击识别器还挂着一个 300ms 的计时器，不等会被测试报“定时器未清”。
Future<void> release(WidgetTester t, TestGesture g) async {
  await g.up();
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('左栏：往右拖变宽', (WidgetTester t) async {
    final r = rig(initial: 200, max: 400);
    await t.pumpWidget(r.build());
    final TestGesture g = await grab(t, dir: 1);
    final double w0 = r.width();
    await g.moveBy(const Offset(60, 0));
    await t.pump();
    expect(r.width(), w0 + 60);
    expect(widthOf(t), w0 + 60);
    await release(t, g);
  });

  testWidgets('右栏：往左拖变宽（方向相反）', (WidgetTester t) async {
    final r = rig(initial: 200, growsRight: false, max: 400);
    await t.pumpWidget(r.build());
    final TestGesture g = await grab(t, dir: -1);
    final double w0 = r.width();
    await g.moveBy(const Offset(-60, 0));
    await t.pump();
    expect(r.width(), w0 + 60);
    await release(t, g);
  });

  testWidgets('撞到上限就停住，拖回来时边跟着鼠标', (WidgetTester t) async {
    final r = rig(initial: 300, max: 300); // 一开始就顶在上限
    await t.pumpWidget(r.build());

    // 拿起手势时已经往右走了 40（被识别器吃掉），之后从这见算。
    final TestGesture g = await grab(t, dir: 1);
    expect(r.width(), 300);

    await g.moveBy(const Offset(40, 0));
    await t.pump();
    expect(r.width(), 300, reason: '撞上限就该停住');

    // 拖回拿起来的位置：增量法这时会往回收（超出多少就少多少），
    // 绝对值法仍然是 300。
    await g.moveBy(const Offset(-40, 0));
    await t.pump();
    expect(r.width(), 300, reason: '回到拿起来的位置就该是原来的宽度');

    // 再往左才是真的变窄。
    await g.moveBy(const Offset(-40, 0));
    await t.pump();
    expect(r.width(), 260);
    await g.moveBy(const Offset(-20, 0));
    await t.pump();
    expect(r.width(), 240);
    await release(t, g);
  });

  testWidgets('撞到下限也停住', (WidgetTester t) async {
    final r = rig(initial: 150, min: 150, max: 400);
    await t.pumpWidget(r.build());
    final TestGesture g = await grab(t, dir: 1);
    await g.moveBy(const Offset(-200, 0));
    await t.pump();
    expect(r.width(), 150);
    await release(t, g);
  });

  testWidgets('双击回到默认宽度', (WidgetTester t) async {
    final r = rig(initial: 380, def: 220);
    await t.pumpWidget(r.build());
    final Offset at = t.getCenter(find.byType(JoSplitter));
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(at);
    await t.pumpAndSettle();
    expect(r.width(), 220);
  });

  testWidgets('松手时喊一声（存盘用）', (WidgetTester t) async {
    final r = rig(initial: 200);
    await t.pumpWidget(r.build());
    final TestGesture g = await grab(t, dir: 1);
    await g.moveBy(const Offset(40, 0));
    await t.pump();
    expect(r.savedOf(), isNull, reason: '还按着就先别存');
    await release(t, g);
    expect(r.savedOf(), r.width());
  });

  test('栏宽存得住，读得回来', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    // 没存过：给 null，界面自己用默认值。
    expect(store.loadRailW(), isNull);
    expect(store.loadSideW(), isNull);

    await store.saveWidths(railW: 233, sideW: 377);
    final SettingsStore again = await SettingsStore.open();
    expect(again.loadRailW(), 233);
    expect(again.loadSideW(), 377);
  });
}
