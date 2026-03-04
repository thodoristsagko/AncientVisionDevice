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

  // Timing budget: target cycle period for a 2 Hz inference rate
  static const double _budgetMs = 500.0;

  // Timing buckets (ms ranges)
  int _bucket0to50 = 0;     // < 50 ms
  int _bucket50to100 = 0;   // 50–100 ms
  int _bucket100to250 = 0;  // 100–250 ms
  int _bucket250to500 = 0;  // 250–500 ms
  int _bucket500plus = 0;   // > 500 ms

  void record(double elapsedMs) {
    _count++;
    _totalMs += elapsedMs;
    if (elapsedMs < _minMs) _minMs = elapsedMs;
    if (elapsedMs > _maxMs) _maxMs = elapsedMs;
    _recent.add(elapsedMs);
    if (_recent.length > _recentWindow) _recent.removeAt(0);

    // Update timing buckets
    if (elapsedMs < 50) {
      _bucket0to50++;
    } else if (elapsedMs < 100) {
      _bucket50to100++;
    } else if (elapsedMs < 250) {
      _bucket100to250++;
    } else if (elapsedMs <= 500) {
      _bucket250to500++;
    } else {
      _bucket500plus++;
    }
  }

  double get avgMs => _count > 0 ? _totalMs / _count : 0.0;
  double get minMs => _count > 0 ? _minMs : 0.0;
  double get maxMs => _maxMs;
  double get rollingAvgMs =>
      _recent.isEmpty ? 0.0 : _recent.reduce((a, b) => a + b) / _recent.length;
  int get count => _count;

  /// 95th percentile of the current rolling window (last [_recentWindow] samples).
  /// Returns 0 when no samples have been recorded yet.
  double get p95Ms {
    if (_recent.isEmpty) return 0.0;
    final sorted = List<double>.from(_recent)..sort();
    final n = sorted.length;
    final idx = 0.95 * (n - 1);
    final lo = idx.floor();
    final hi = idx.ceil();
    if (lo == hi) return sorted[lo];
    final frac = idx - lo;
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
  }

  /// Fraction of the 500 ms (2 Hz) budget consumed by the average inference.
  /// A value >1.0 means the service cannot sustain a 2 Hz rate.
  double get budgetUtilization => avgMs / _budgetMs;

  /// Human-readable rate recommendation based on p95 latency.
  String get throttleRecommendation {
    final p95 = p95Ms;
    if (p95 > 400) return 'Reduce to 1Hz';
    if (p95 < 100) return 'Can run at 4Hz';
    return '2Hz is optimal';
  }

  /// Count of recorded samples grouped into five latency buckets.
  Map<String, int> get timingBuckets => {
        '<50ms': _bucket0to50,
        '50-100ms': _bucket50to100,
        '100-250ms': _bucket100to250,
        '250-500ms': _bucket250to500,
        '>500ms': _bucket500plus,
      };

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
    _bucket0to50 = 0;
    _bucket50to100 = 0;
    _bucket100to250 = 0;
    _bucket250to500 = 0;
    _bucket500plus = 0;
  }
}
