/// Tracks ML inference timing statistics for the safety view diagnostics panel.
class InferenceTimingService {
  InferenceTimingService._();
  static final InferenceTimingService instance = InferenceTimingService._();

  int _count = 0;
  double _totalMs = 0.0;
  double _minMs = double.infinity;
  double _maxMs = 0.0;
  final List<double> _recent = []; // Last 20 samples for rolling average
  static const int _recentWindow = 20;

  void record(double elapsedMs) {
    _count++;
    _totalMs += elapsedMs;
    if (elapsedMs < _minMs) _minMs = elapsedMs;
    if (elapsedMs > _maxMs) _maxMs = elapsedMs;
    _recent.add(elapsedMs);
    if (_recent.length > _recentWindow) _recent.removeAt(0);
  }

  double get avgMs => _count > 0 ? _totalMs / _count : 0.0;
  double get minMs => _count > 0 ? _minMs : 0.0;
  double get maxMs => _maxMs;
  double get rollingAvgMs =>
      _recent.isEmpty ? 0.0 : _recent.reduce((a, b) => a + b) / _recent.length;
  int get count => _count;

  String get summary =>
      'avg=${avgMs.toStringAsFixed(1)}ms  '
      'rolling=${rollingAvgMs.toStringAsFixed(1)}ms  '
      'min=${minMs.toStringAsFixed(1)}ms  '
      'max=${maxMs.toStringAsFixed(1)}ms  '
      'n=$count';

  void reset() {
    _count = 0;
    _totalMs = 0.0;
    _minMs = double.infinity;
    _maxMs = 0.0;
    _recent.clear();
  }
}
