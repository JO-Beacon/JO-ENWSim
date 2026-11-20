import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/memory_agent.dart';

void main() {
  test('M encode 只接受本轮允许的事件', () {
    final List<CharacterMemory> out = applyMemoryOperations(
      characterId: 'char:灵梦',
      current: const <CharacterMemory>[],
      operations: const <MemoryOperation>[
        MemoryOperation(
          op: 'encode',
          text: '我看见信标把急救包藏到身后。',
          sourceEvents: <String>['evt-1'],
        ),
      ],
      allowedEventIds: <String>{'evt-1'},
    );
    expect(out, hasLength(1));
    expect(out.single.characterId, 'char:灵梦');
    expect(out.single.sourceEvents, <String>['evt-1']);
  });

  test('M 操作有一条不合格时整批不写', () {
    expect(
      () => applyMemoryOperations(
        characterId: 'char:灵梦',
        current: const <CharacterMemory>[],
        operations: const <MemoryOperation>[
          MemoryOperation(
            op: 'encode',
            text: '一条合法记忆。',
            sourceEvents: <String>['evt-1'],
          ),
          MemoryOperation(
            op: 'reinforce',
            memoryId: '不存在',
            text: '改写。',
          ),
        ],
        allowedEventIds: <String>{'evt-1'},
      ),
      throwsA(isA<MemoryAgentException>()),
    );
  });

  test('compress 生成摘要并把旧记忆归档', () {
    final CharacterMemory a = CharacterMemory(
      id: 'cm-a',
      characterId: 'char:灵梦',
      text: '第一条。',
      sourceEvents: const <String>['evt-1'],
    );
    final CharacterMemory b = CharacterMemory(
      id: 'cm-b',
      characterId: 'char:灵梦',
      text: '第二条。',
      sourceEvents: const <String>['evt-2'],
    );
    final List<CharacterMemory> out = applyMemoryOperations(
      characterId: 'char:灵梦',
      current: <CharacterMemory>[a, b],
      operations: const <MemoryOperation>[
        MemoryOperation(
          op: 'compress',
          memoryIds: <String>['cm-a', 'cm-b'],
          text: '两件事连起来看。',
        ),
      ],
      allowedEventIds: const <String>{},
    );
    expect(out, hasLength(3));
    expect(
      out.where((CharacterMemory m) => m.state == MemoryState.archived),
      hasLength(2),
    );
    expect(
      out.where((CharacterMemory m) => m.state == MemoryState.compressed),
      hasLength(1),
    );
  });
}
