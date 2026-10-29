/// A map that keeps at most [capacity] entries. Reading or writing an entry makes
/// it the newest; adding one past the limit drops the entry used longest ago.
class LruCache<K, V extends Object> {
  LruCache(this.capacity) : assert(capacity > 0);

  final int capacity;

  // A Dart map iterates in insertion order, so the first key is the oldest.
  final Map<K, V> _entries = {};

  int get length => _entries.length;

  /// Every value, oldest first. Does not change the order.
  Iterable<V> get values => _entries.values;

  /// Replaces every value with what [update] makes of it. Keeps the order.
  void updateAll(V Function(K key, V value) update) => _entries.updateAll(update);

  /// The value for [key], marked as just used, or null.
  V? operator [](K key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void operator []=(K key, V value) {
    _entries
      ..remove(key)
      ..[key] = value;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
  }

  /// The value for [key] without marking it as used.
  V? peek(K key) => _entries[key];

  V? remove(K key) => _entries.remove(key);

  /// Drops every entry whose key satisfies [test].
  void removeWhere(bool Function(K key) test) =>
      _entries.removeWhere((key, _) => test(key));

  void clear() => _entries.clear();
}
