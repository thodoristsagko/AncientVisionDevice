import 'package:vector_math/vector_math_64.dart';
import '../models/point_cloud.dart';

/// A simple KD-tree implementation for fast nearest-neighbor search in 3D point clouds.
/// Reduces complexity from O(N²) to O(N log N) for spatial queries.
class KDTree {
  KDNode? _root;
  final List<Point3D> _points;

  KDTree(this._points) {
    if (_points.isNotEmpty) {
      _root = _buildTree(_points, 0);
    }
  }

  /// Build the KD-tree recursively
  KDNode? _buildTree(List<Point3D> points, int depth) {
    if (points.isEmpty) return null;

    // Cycle through dimensions (x=0, y=1, z=2)
    final axis = depth % 3;

    // Sort points by the current axis
    points.sort((a, b) {
      final aVal = _getAxisValue(a.position, axis);
      final bVal = _getAxisValue(b.position, axis);
      return aVal.compareTo(bVal);
    });

    // Choose median as pivot
    final medianIdx = points.length ~/ 2;
    final medianPoint = points[medianIdx];

    // Recursively build left and right subtrees
    final leftPoints = points.sublist(0, medianIdx);
    final rightPoints = points.sublist(medianIdx + 1);

    return KDNode(
      point: medianPoint,
      axis: axis,
      left: _buildTree(leftPoints, depth + 1),
      right: _buildTree(rightPoints, depth + 1),
    );
  }

  double _getAxisValue(Vector3 position, int axis) {
    switch (axis) {
      case 0: return position.x;
      case 1: return position.y;
      case 2: return position.z;
      default: return position.x;
    }
  }

  /// Find the K nearest neighbors to a given point
  List<Point3D> findKNearest(Vector3 target, int k) {
    if (_root == null || k <= 0) return [];

    final heap = _PriorityQueue<_DistanceEntry>(
      compare: (a, b) => b.distance.compareTo(a.distance), // Max-heap
    );

    _searchKNearest(_root!, target, k, heap);

    // Extract points from heap in sorted order
    final result = <Point3D>[];
    while (heap.isNotEmpty) {
      result.insert(0, heap.removeFirst().point);
    }
    return result;
  }

  void _searchKNearest(
    KDNode node,
    Vector3 target,
    int k,
    _PriorityQueue<_DistanceEntry> heap,
  ) {
    final distance = (node.point.position - target).length;

    // Add to heap if we don't have k points yet, or if this is closer than the farthest
    if (heap.length < k) {
      heap.add(_DistanceEntry(node.point, distance));
    } else if (distance < heap.first.distance) {
      heap.removeFirst();
      heap.add(_DistanceEntry(node.point, distance));
    }

    // Determine which side to search first
    final targetVal = _getAxisValue(target, node.axis);
    final nodeVal = _getAxisValue(node.point.position, node.axis);
    final diff = targetVal - nodeVal;

    final firstChild = diff < 0 ? node.left : node.right;
    final secondChild = diff < 0 ? node.right : node.left;

    // Search the near side first
    if (firstChild != null) {
      _searchKNearest(firstChild, target, k, heap);
    }

    // Check if we need to search the far side
    // (if the splitting plane is within the current search radius)
    if (secondChild != null) {
      final splitDist = diff.abs();
      if (heap.length < k || splitDist < heap.first.distance) {
        _searchKNearest(secondChild, target, k, heap);
      }
    }
  }

  /// Find all points within a given radius
  List<Point3D> findInRadius(Vector3 target, double radius) {
    if (_root == null) return [];

    final result = <Point3D>[];
    _searchInRadius(_root!, target, radius * radius, result); // Use squared distance
    return result;
  }

  void _searchInRadius(
    KDNode node,
    Vector3 target,
    double radiusSquared,
    List<Point3D> result,
  ) {
    final distSquared = (node.point.position - target).length2;

    if (distSquared <= radiusSquared) {
      result.add(node.point);
    }

    final targetVal = _getAxisValue(target, node.axis);
    final nodeVal = _getAxisValue(node.point.position, node.axis);
    final diff = targetVal - nodeVal;

    // Search both sides if the splitting plane intersects the search sphere
    if (diff < 0) {
      if (node.left != null) {
        _searchInRadius(node.left!, target, radiusSquared, result);
      }
      if (node.right != null && diff * diff <= radiusSquared) {
        _searchInRadius(node.right!, target, radiusSquared, result);
      }
    } else {
      if (node.right != null) {
        _searchInRadius(node.right!, target, radiusSquared, result);
      }
      if (node.left != null && diff * diff <= radiusSquared) {
        _searchInRadius(node.left!, target, radiusSquared, result);
      }
    }
  }
}

/// Node in the KD-tree
class KDNode {
  final Point3D point;
  final int axis; // 0=x, 1=y, 2=z
  final KDNode? left;
  final KDNode? right;

  KDNode({
    required this.point,
    required this.axis,
    this.left,
    this.right,
  });
}

/// Helper class for distance-based priority queue entries
class _DistanceEntry {
  final Point3D point;
  final double distance;

  _DistanceEntry(this.point, this.distance);
}

/// Simple priority queue implementation using a heap
class _PriorityQueue<T> {
  final List<T> _items = [];
  final int Function(T a, T b) compare;

  _PriorityQueue({required this.compare});

  void add(T item) {
    _items.add(item);
    _bubbleUp(_items.length - 1);
  }

  T removeFirst() {
    if (_items.isEmpty) {
      throw StateError('Cannot remove from empty queue');
    }

    final first = _items[0];
    final last = _items.removeLast();

    if (_items.isNotEmpty) {
      _items[0] = last;
      _bubbleDown(0);
    }

    return first;
  }

  T get first {
    if (_items.isEmpty) {
      throw StateError('Cannot get first from empty queue');
    }
    return _items[0];
  }

  int get length => _items.length;
  bool get isNotEmpty => _items.isNotEmpty;
  bool get isEmpty => _items.isEmpty;

  void _bubbleUp(int index) {
    while (index > 0) {
      final parentIndex = (index - 1) ~/ 2;
      if (compare(_items[index], _items[parentIndex]) >= 0) break;

      _swap(index, parentIndex);
      index = parentIndex;
    }
  }

  void _bubbleDown(int index) {
    while (true) {
      var smallest = index;
      final leftChild = 2 * index + 1;
      final rightChild = 2 * index + 2;

      if (leftChild < _items.length &&
          compare(_items[leftChild], _items[smallest]) < 0) {
        smallest = leftChild;
      }

      if (rightChild < _items.length &&
          compare(_items[rightChild], _items[smallest]) < 0) {
        smallest = rightChild;
      }

      if (smallest == index) break;

      _swap(index, smallest);
      index = smallest;
    }
  }

  void _swap(int i, int j) {
    final temp = _items[i];
    _items[i] = _items[j];
    _items[j] = temp;
  }
}
