import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/ui/memory_diff.dart';

void main() {
  test('逐行 diff 标出新增、删除和未变行', () {
    final List<MemoryDiffLine> lines = memoryLineDiff(
      '我推开门。\n门后很暗。',
      '我推开门。\n门后很暗。\n雨声更近了。',
    );
    expect(lines, hasLength(3));
    expect(lines[0].kind, MemoryDiffKind.same);
    expect(lines[1].kind, MemoryDiffKind.same);
    expect(lines[2].kind, MemoryDiffKind.add);
    expect(lines[2].newLine, 3);
  });

  test('替换行同时产生删除和新增', () {
    final List<MemoryDiffLine> lines = memoryLineDiff(
      '第一版。',
      '第二版。',
    );
    expect(
      lines.where((MemoryDiffLine l) => l.kind == MemoryDiffKind.remove),
      hasLength(1),
    );
    expect(
      lines.where((MemoryDiffLine l) => l.kind == MemoryDiffKind.add),
      hasLength(1),
    );
  });
}
