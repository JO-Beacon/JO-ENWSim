// 悬停文字提示。
//
// 钉住三件事：
//   1. 停上去要等一小会儿才浮出来（不能一划过就一路闪）；
//   2. 名字确实浮在界面上（Overlay 里能找到那行字）；
//   3. 鼠标移开就收回去，而且不留计时器（不然测试和退出都会有不干净的尾巴）。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/tooltip.dart';

Widget host(Widget child) => MaterialApp(
  home: JoTheme(
    settings: const JoSettings(),
    palette: JoPalette.dark,
    child: Scaffold(body: Center(child: child)),
  ),
);

Widget anchor({Duration? wait}) => JoTooltip(
  text: '编辑这个世界',
  wait: wait ?? const Duration(milliseconds: 350),
  child: const SizedBox(
    width: 60,
    height: 30,
    child: ColoredBox(color: Colors.black),
  ),
);

void main() {
  testWidgets('停上去等一会儿才浮出来，移开就收', (WidgetTester t) async {
    await t.pumpWidget(host(anchor()));

    final TestGesture mouse = await t.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await t.pump();

    await mouse.moveTo(t.getCenter(find.byType(SizedBox).last));
    await t.pump();
    // 刚停上去：还不该出现（等了才出来，才不至于划过一排图标一路闪）。
    expect(find.text('编辑这个世界'), findsNothing);

    // 等过 [wait]，浮层才插进来。
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
    expect(find.text('编辑这个世界'), findsOneWidget);

    // 移开：收回去。
    await mouse.moveTo(const Offset(1, 1));
    await t.pumpAndSettle();
    expect(find.text('编辑这个世界'), findsNothing);
  });

  testWidgets('划过就移开：计时器取消，什么都不留', (WidgetTester t) async {
    await t.pumpWidget(host(anchor()));

    final TestGesture mouse = await t.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await t.pump();

    await mouse.moveTo(t.getCenter(find.byType(SizedBox).last));
    await t.pump();
    await mouse.moveTo(const Offset(1, 1));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('编辑这个世界'), findsNothing);
  });

  testWidgets('等的时间可以调（这里调成 0：立刻出来）', (WidgetTester t) async {
    await t.pumpWidget(host(anchor(wait: Duration.zero)));

    final TestGesture mouse = await t.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await t.pump();

    await mouse.moveTo(t.getCenter(find.byType(SizedBox).last));
    await t.pump();
    await t.pump(const Duration(milliseconds: 1));
    expect(find.text('编辑这个世界'), findsOneWidget);
  });

  // 以前浮层的尺寸是死算的（测量宽 + 内边距 + 单行省略），
  // 量得差一点点字尾就被“…”截掉。现在尺寸由文字自己决定。
  testWidgets('浮层尺寸跟着文字走，不截断（含系统字体缩放）', (WidgetTester t) async {
    const String long = '取消选中这一步（这是一段比较长的提示文字）';
    const TextScaler scaler = TextScaler.linear(1.5);

    await t.pumpWidget(
      host(
        MediaQuery(
          data: const MediaQueryData(textScaler: scaler),
          child: JoTooltip(
            text: long,
            wait: Duration.zero,
            child: const SizedBox(width: 24, height: 24),
          ),
        ),
      ),
    );

    final TestGesture mouse = await t.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await t.pump();
    await mouse.moveTo(t.getCenter(find.byType(SizedBox).last));
    await t.pump();
    await t.pump(const Duration(milliseconds: 1));

    final Finder text = find.text(long);
    expect(text, findsOneWidget);

    // 同一套样式 + 同一个缩放量出来的尺寸，应该和真渲染的一致。
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: long,
        style: JoFonts.meta.copyWith(color: JoPalette.dark.text, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final Size rendered = t.getSize(text);
    expect(rendered.width, closeTo(tp.width, 1));
    expect(rendered.height, closeTo(tp.height, 1));

    // 外层板不能比文字窄（窄了就是“显示不全”）。
    final Size panel = t.getSize(
      find.ancestor(of: text, matching: find.byType(Container)).last,
    );
    expect(
      panel.width,
      greaterThanOrEqualTo(rendered.width + JoSpace.s2 * 2 - 0.5),
    );
    expect(
      panel.height,
      greaterThanOrEqualTo(rendered.height + JoSpace.s1 * 2 - 0.5),
    );
  });
}
