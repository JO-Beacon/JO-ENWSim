// 记忆版本的逐行 diff。
//
// 只做展示，不改历史：旧版和新版都按行比较，输出 same / add / remove。
// 版本本身仍由 memory_version 表追加，恢复旧版会生成新版本。

enum MemoryDiffKind { same, add, remove }

class MemoryDiffLine {
  const MemoryDiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final MemoryDiffKind kind;
  final String text;

  /// 1-based 行号；新增行没有旧行号，删除行没有新行号。
  final int? oldLine;
  final int? newLine;
}

/// 用 LCS 做逐行 diff。记忆正文通常很短，直接 O(n*m) 即可。
List<MemoryDiffLine> memoryLineDiff(String oldText, String newText) {
  final List<String> oldLines = oldText.split('\n');
  final List<String> newLines = newText.split('\n');
  final int n = oldLines.length;
  final int m = newLines.length;
  final List<List<int>> dp = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      dp[i][j] = oldLines[i] == newLines[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] > dp[i][j + 1]
              ? dp[i + 1][j]
              : dp[i][j + 1]);
    }
  }

  final List<MemoryDiffLine> out = <MemoryDiffLine>[];
  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      out.add(
        MemoryDiffLine(
          kind: MemoryDiffKind.same,
          text: oldLines[i],
          oldLine: i + 1,
          newLine: j + 1,
        ),
      );
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(
        MemoryDiffLine(
          kind: MemoryDiffKind.remove,
          text: oldLines[i],
          oldLine: i + 1,
        ),
      );
      i++;
    } else {
      out.add(
        MemoryDiffLine(
          kind: MemoryDiffKind.add,
          text: newLines[j],
          newLine: j + 1,
        ),
      );
      j++;
    }
  }
  while (i < n) {
    out.add(
      MemoryDiffLine(
        kind: MemoryDiffKind.remove,
        text: oldLines[i],
        oldLine: i + 1,
      ),
    );
    i++;
  }
  while (j < m) {
    out.add(
      MemoryDiffLine(
        kind: MemoryDiffKind.add,
        text: newLines[j],
        newLine: j + 1,
      ),
    );
    j++;
  }
  return out;
}
