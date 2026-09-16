import 'dart:convert';
import 'dart:typed_data';

import '../graph/graph_types.dart';
import '../spatial/kd_tree.dart';
import 'graph_serializer.dart';

/// Thrown when a serialized payload is malformed, truncated, or written for an
/// incompatible format version or byte order.
class GraphFormatException implements Exception {
  final String message;
  const GraphFormatException(this.message);
  @override
  String toString() => 'GraphFormatException: $message';
}

/// Reconstructs [RoutingGraph]s and [KdTree]s from the binary format produced by
/// [GraphSerializer].
///
/// When the input is 8-byte aligned (always true for bytes read straight from a
/// file) the CSR arrays are returned as zero-copy views over the input buffer,
/// so loading is dominated by the OS read itself.
class GraphDeserializer {
  const GraphDeserializer();

  Uint8List _aligned(Uint8List bytes) {
    if (bytes.offsetInBytes % 8 != 0) return Uint8List.fromList(bytes);
    return bytes;
  }

  /// Decodes a `.graph` payload into a [RoutingGraph].
  RoutingGraph deserializeGraph(Uint8List input) {
    final bytes = _aligned(input);
    if (bytes.length < 32) {
      throw const GraphFormatException('graph payload too small');
    }
    if (bytes[0] != 0x47 ||
        bytes[1] != 0x52 ||
        bytes[2] != 0x46 ||
        bytes[3] != 0x31) {
      throw const GraphFormatException('bad graph magic');
    }
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final version = bd.getInt32(4, Endian.little);
    if (version != kGraphFormatVersion) {
      throw GraphFormatException('unsupported graph version $version');
    }
    final endian = bd.getInt32(8, Endian.little);
    if (endian != hostEndianFlag()) {
      throw const GraphFormatException(
        'graph was written with a different byte order than this host',
      );
    }
    final n = bd.getInt32(12, Endian.little);
    final m = bd.getInt32(16, Endian.little);
    final gp = bd.getInt32(20, Endian.little);
    final flags = bd.getInt32(24, Endian.little);
    final condBytes = bd.getInt32(28, Endian.little);

    final base = bytes.offsetInBytes;
    var off = base + 32;
    Float64List takeF64(int len) {
      final v = bytes.buffer.asFloat64List(off, len);
      off += len * 8;
      return v;
    }

    Int64List takeI64(int len) {
      final v = bytes.buffer.asInt64List(off, len);
      off += len * 8;
      return v;
    }

    Int32List takeI32(int len) {
      final v = bytes.buffer.asInt32List(off, len);
      off += len * 4;
      return v;
    }

    Uint8List takeU8(int len) {
      final v = bytes.buffer.asUint8List(off, len);
      off += len;
      return v;
    }

    final lat = takeF64(n);
    final lon = takeF64(n);
    final originalId = takeI64(n);
    final adjTime = takeF64(m);
    final adjDist = takeF64(m);
    final geomCoords = takeF64(2 * gp);
    final adjOffset = takeI32(n + 1);
    final adjTarget = takeI32(m);
    final geomOffset = takeI32(m + 1);
    final splitParent = (flags & kGraphFlagHasSplitParent) != 0
        ? takeI32(n)
        : null;
    final adjToll = takeU8(m);
    final adjSignal = takeU8(m);
    final adjAccess = takeU8(m);

    Uint8List? adjCond;
    var conditions = const <String>[];
    if ((flags & kGraphFlagHasConditions) != 0) {
      adjCond = takeU8(m);
      conditions = _decodeConditions(takeU8(condBytes));

      // Checked here rather than discovered mid-query. `conditionOf` is called
      // inside the relaxation loops, where a bad index has no good outcome: it
      // either throws in the middle of a search or, worse, reads a neighbouring
      // junction's timetable and says a banned turn is open.
      for (var e = 0; e < m; e++) {
        if (adjCond[e] > conditions.length) {
          throw GraphFormatException(
            'edge $e names condition ${adjCond[e]} of ${conditions.length}',
          );
        }
      }
    }

    return RoutingGraph(
      lat: lat,
      lon: lon,
      originalId: originalId,
      adjOffset: adjOffset,
      adjTarget: adjTarget,
      adjTime: adjTime,
      adjDist: adjDist,
      adjToll: adjToll,
      adjSignal: adjSignal,
      adjAccess: adjAccess,
      geomCoords: geomCoords,
      geomOffset: geomOffset,
      splitParent: splitParent,
      adjCond: adjCond,
      conditions: conditions,
    );
  }

  /// Decodes the length-prefixed condition table written by [GraphSerializer].
  ///
  /// Every length is validated against what is left of the blob, so a truncated
  /// or mislabelled table is a [GraphFormatException] and not a `RangeError`
  /// raised from inside a typed-data view.
  List<String> _decodeConditions(Uint8List blob) {
    if (blob.isEmpty) return const [];
    if (blob.length < 4) {
      throw const GraphFormatException('condition table too small');
    }

    final bd = ByteData.view(blob.buffer, blob.offsetInBytes, blob.length);
    final count = bd.getInt32(0, Endian.little);
    // Each entry costs at least its own 4-byte length, so a count that could
    // not fit is rejected before anything is allocated for it.
    if (count < 0 || 4 + 4 * count > blob.length) {
      throw GraphFormatException('condition table declares $count conditions');
    }

    final conditions = <String>[];
    var off = 4;
    for (var i = 0; i < count; i++) {
      final len = bd.getInt32(off, Endian.little);
      off += 4;
      if (len < 0 || off + len > blob.length) {
        throw GraphFormatException('condition $i has length $len');
      }
      conditions.add(utf8.decode(blob.sublist(off, off + len)));
      off += len;
    }
    if (off != blob.length) {
      throw GraphFormatException(
        'condition table has ${blob.length - off} trailing bytes',
      );
    }
    return conditions;
  }

  /// Decodes an `.index` payload into a [KdTree] bound to [graph].
  KdTree deserializeIndex(Uint8List input, RoutingGraph graph) {
    final bytes = _aligned(input);
    if (bytes.length < 24) {
      throw const GraphFormatException('index payload too small');
    }
    if (bytes[0] != 0x49 ||
        bytes[1] != 0x44 ||
        bytes[2] != 0x58 ||
        bytes[3] != 0x31) {
      throw const GraphFormatException('bad index magic');
    }
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final version = bd.getInt32(4, Endian.little);
    if (version != kGraphFormatVersion) {
      throw GraphFormatException('unsupported index version $version');
    }
    final endian = bd.getInt32(8, Endian.little);
    if (endian != hostEndianFlag()) {
      throw const GraphFormatException(
        'index was written with a different byte order than this host',
      );
    }
    final count = bd.getInt32(12, Endian.little);
    // A short read here is a `RangeError` out of `asInt32List` with nothing to
    // say which file caused it; a long one silently reads whatever follows the
    // payload in the buffer as vertex indices.
    if (count < 0 || 24 + 4 * count > bytes.length) {
      throw GraphFormatException(
        'index declares $count entries but carries ${bytes.length - 24} bytes',
      );
    }

    final cosRef = bd.getFloat64(16, Endian.little);
    final order = bytes.buffer.asInt32List(bytes.offsetInBytes + 24, count);

    // The index is a permutation of *vertices*, and every lookup uses its
    // entries to subscript the graph's coordinate arrays. An entry out of range
    // throws from deep inside a nearest-neighbour descent, where the error says
    // nothing about the mismatched pair of files that caused it — which is the
    // likely cause, an `.index` left behind by a graph that has since been
    // rebuilt smaller.
    for (var i = 0; i < count; i++) {
      if (order[i] < 0 || order[i] >= graph.nodeCount) {
        throw GraphFormatException(
          'index entry $i is vertex ${order[i]}, outside the graph\'s '
          '${graph.nodeCount} vertices',
        );
      }
    }
    return KdTree.fromOrder(graph, order, cosRef);
  }
}
