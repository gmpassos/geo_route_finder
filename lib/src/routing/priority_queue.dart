import 'dart:typed_data';

/// A compact binary min-heap keyed by `double` cost, carrying an `int` payload
/// (a vertex index).
///
/// It stores keys and values in growable [TypedData] arrays to avoid per-entry
/// object allocation, which matters a great deal in the inner loop of Dijkstra
/// and A* on large graphs. Decrease-key is handled lazily: callers push a new,
/// lower-cost entry and discard stale pops by comparing against their best-known
/// distance. This is the standard, allocation-light approach and is faster in
/// practice than maintaining an index map for road networks.
class MinHeap {
  Float64List _keys;
  Int32List _vals;
  int _size = 0;

  MinHeap([int initialCapacity = 1024])
    : _keys = Float64List(initialCapacity < 1 ? 1 : initialCapacity),
      _vals = Int32List(initialCapacity < 1 ? 1 : initialCapacity);

  bool get isEmpty => _size == 0;
  bool get isNotEmpty => _size != 0;
  int get length => _size;

  void clear() => _size = 0;

  void push(double key, int value) {
    if (_size == _keys.length) _grow();
    var i = _size++;
    _keys[i] = key;
    _vals[i] = value;
    // Sift up.
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_keys[parent] <= _keys[i]) break;
      _swap(i, parent);
      i = parent;
    }
  }

  /// The smallest key currently in the heap. Call only when non-empty.
  double get peekKey => _keys[0];

  /// The payload associated with the smallest key. Call only when non-empty.
  int get peekValue => _vals[0];

  /// Removes and returns the payload with the smallest key.
  int pop() {
    final top = _vals[0];
    _size--;
    if (_size > 0) {
      _keys[0] = _keys[_size];
      _vals[0] = _vals[_size];
      _siftDown(0);
    }
    return top;
  }

  void _siftDown(int i) {
    final n = _size;
    while (true) {
      final l = 2 * i + 1;
      final r = l + 1;
      var smallest = i;
      if (l < n && _keys[l] < _keys[smallest]) smallest = l;
      if (r < n && _keys[r] < _keys[smallest]) smallest = r;
      if (smallest == i) break;
      _swap(i, smallest);
      i = smallest;
    }
  }

  void _swap(int a, int b) {
    final kt = _keys[a];
    _keys[a] = _keys[b];
    _keys[b] = kt;
    final vt = _vals[a];
    _vals[a] = _vals[b];
    _vals[b] = vt;
  }

  void _grow() {
    final newCap = _keys.length * 2;
    final nk = Float64List(newCap);
    final nv = Int32List(newCap);
    nk.setRange(0, _size, _keys);
    nv.setRange(0, _size, _vals);
    _keys = nk;
    _vals = nv;
  }
}
