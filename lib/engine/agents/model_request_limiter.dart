import 'dart:async';
import 'dart:collection';

/// 工作台的模型传输共用一条队列。调低上限时，让在途请求自然结束。
class ModelRequestLimiter {
  ModelRequestLimiter(int limit) : _limit = limit < 1 ? 1 : limit;

  int _limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  set limit(int value) {
    _limit = value < 1 ? 1 : value;
    _admitWaiting();
  }

  /// 已取得名额时返回 null，否则等待队列分配。
  Future<void>? acquire() {
    if (_active >= _limit || _waiting.isNotEmpty) {
      final Completer<void> ready = Completer<void>();
      _waiting.addLast(ready);
      return ready.future;
    }
    _active++;
    return null;
  }

  void release() {
    _active--;
    _admitWaiting();
  }

  void _admitWaiting() {
    while (_active < _limit && _waiting.isNotEmpty) {
      _active++;
      _waiting.removeFirst().complete();
    }
  }
}
