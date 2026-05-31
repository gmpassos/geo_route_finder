import 'dart:typed_data';

import '../graph/graph_types.dart';
import '../spatial/kd_tree.dart';

/// On-disk format version. Bump on any breaking layout change.
///
/// v2 added the per-edge `adjToll` array (one byte per directed edge), appended
/// after the existing 8- and 4-byte arrays to preserve their alignment.
const int kGraphFormatVersion = 2;

/// `'GRF1'` magic for the `.graph` payload.
const int _graphMagic0 = 0x47; // G
const int _graphMagic1 = 0x52; // R
const int _graphMagic2 = 0x46; // F
const int _graphMagic3 = 0x31; // 1

/// `'IDX1'` magic for the `.index` payload.
const int _indexMagic0 = 0x49; // I
const int _indexMagic1 = 0x44; // D
const int _indexMagic2 = 0x58; // X
const int _indexMagic3 = 0x31; // 1

/// Encodes the value of [Endian.host] as a stored flag.
int hostEndianFlag() => Endian.host == Endian.little ? 1 : 2;

/// Serializes [RoutingGraph]s and [KdTree]s into the package's compact binary
/// format.
///
/// The layout places all 8-byte arrays first so that every array begins on an
/// 8-byte boundary. Combined with a header padded to 24 bytes, this lets the
/// matching deserializer return *views* directly over the file bytes — true
/// zero-copy loading. Bulk array data is written in host byte order (recorded in
/// the header) for speed; the tiny header is always little-endian.
class GraphSerializer {
  const GraphSerializer();

  /// Serializes the CSR routing graph into a `.graph` payload.
  Uint8List serializeGraph(RoutingGraph g) {
    final n = g.nodeCount;
    final m = g.edgeCount;
    final gp = g.geomCoords.length ~/ 2;

    const header = 24;
    final f64Bytes = 8 * (3 * n + 2 * m + 2 * gp);
    final i32Bytes = 4 * ((n + 1) + m + (m + 1));
    final u8Bytes = m; // adjToll, one byte per edge
    final total = header + f64Bytes + i32Bytes + u8Bytes;

    final out = Uint8List(total);
    final bd = ByteData.view(out.buffer);
    out[0] = _graphMagic0;
    out[1] = _graphMagic1;
    out[2] = _graphMagic2;
    out[3] = _graphMagic3;
    bd.setInt32(4, kGraphFormatVersion, Endian.little);
    bd.setInt32(8, hostEndianFlag(), Endian.little);
    bd.setInt32(12, n, Endian.little);
    bd.setInt32(16, m, Endian.little);
    bd.setInt32(20, gp, Endian.little);

    var off = header;
    void putF64(Float64List src) {
      out.buffer.asFloat64List(off, src.length).setRange(0, src.length, src);
      off += src.length * 8;
    }

    void putI64(Int64List src) {
      out.buffer.asInt64List(off, src.length).setRange(0, src.length, src);
      off += src.length * 8;
    }

    void putI32(Int32List src) {
      out.buffer.asInt32List(off, src.length).setRange(0, src.length, src);
      off += src.length * 4;
    }

    putF64(g.lat);
    putF64(g.lon);
    putI64(g.originalId);
    putF64(g.adjTime);
    putF64(g.adjDist);
    putF64(g.geomCoords);
    putI32(g.adjOffset);
    putI32(g.adjTarget);
    putI32(g.geomOffset);
    // 1-byte array last so the 8- and 4-byte arrays above stay aligned.
    out.setRange(off, off + g.adjToll.length, g.adjToll);
    off += g.adjToll.length;

    return out;
  }

  /// Serializes a [KdTree] into an `.index` payload (its [KdTree.order]
  /// permutation plus the reference cosine).
  Uint8List serializeIndex(KdTree tree) {
    final count = tree.order.length;
    const header = 24; // 16 bytes + 8-byte cosRef
    final total = header + 4 * count;
    final out = Uint8List(total);
    final bd = ByteData.view(out.buffer);
    out[0] = _indexMagic0;
    out[1] = _indexMagic1;
    out[2] = _indexMagic2;
    out[3] = _indexMagic3;
    bd.setInt32(4, kGraphFormatVersion, Endian.little);
    bd.setInt32(8, hostEndianFlag(), Endian.little);
    bd.setInt32(12, count, Endian.little);
    bd.setFloat64(16, tree.cosRef, Endian.little);
    out.buffer.asInt32List(header, count).setRange(0, count, tree.order);
    return out;
  }
}
