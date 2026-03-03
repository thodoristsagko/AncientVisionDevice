import 'dart:collection';

/// O(1) circular buffer backed by a doubly-linked [Queue].
///
/// Replaces `List + removeAt(0)` patterns which are O(N) due to element
/// shifting. Uses Dart's [Queue] which provides O(1) `removeFirst()` and
/// `addLast()` via a doubly-linked list.
///
/// Reference: Knuth (1997) "The Art of Computer Programming, Vol. 1" S2.2.2
class CircularBuffer<T> {
  final int capacity;
  final Queue<T> _queue = Queue<T>();

  CircularBuffer(this.capacity) : assert(capacity > 0);

  /// Add an item, evicting the oldest if at capacity. O(1).
  void add(T item) {
    if (_queue.length >= capacity) _queue.removeFirst();
    _queue.addLast(item);
  }

  /// Snapshot as a growable [List]. O(N).
  List<T> toList() => _queue.toList();

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;
  bool get isNotEmpty => _queue.isNotEmpty;
  T get last => _queue.last;
  T get first => _queue.first;

  void clear() => _queue.clear();

  /// Iterate without copying.
  Iterable<T> get iter => _queue;
}
