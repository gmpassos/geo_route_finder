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
    if (bytes.length < 24) {
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

    final base = bytes.offsetInBytes;
    var off = base + 24;
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

    final lat = takeF64(n);
    final lon = takeF64(n);
    final originalId = takeI64(n);
    final adjTime = takeF64(m);
    final adjDist = takeF64(m);
    final geomCoords = takeF64(2 * gp);
    final adjOffset = takeI32(n + 1);
    final adjTarget = takeI32(m);
    final geomOffset = takeI32(m + 1);

    return RoutingGraph(
      lat: lat,
      lon: lon,
      originalId: originalId,
      adjOffset: adjOffset,
      adjTarget: adjTarget,
      adjTime: adjTime,
      adjDist: adjDist,
      geomCoords: geomCoords,
      geomOffset: geomOffset,
    );
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
    final cosRef = bd.getFloat64(16, Endian.little);
    final order = bytes.buffer.asInt32List(bytes.offsetInBytes + 24, count);
    return KdTree.fromOrder(graph, order, cosRef);
  }
}
