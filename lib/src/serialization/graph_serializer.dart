import 'dart:convert';
import 'dart:typed_data';

import '../graph/graph_types.dart';
import '../spatial/kd_tree.dart';

/// On-disk format version. Bump on any breaking layout change.
///
/// v2 added the per-edge `adjToll` array (one byte per directed edge), appended
/// after the existing 8- and 4-byte arrays to preserve their alignment.
///
/// v3 added `adjSignal` beside it, on the same terms and for the same reason:
/// a count of signalised junctions entered per edge.
///
/// v4 added turn restrictions, which arrive in two shapes. An unconditional
/// one is *topology* — the junction is split so the forbidden movement has no
/// edge — needing no new array beyond `splitParent` to say which vertices are
/// copies. A conditional one cannot be topology, because one graph has to
/// answer both "restricted now" and "not restricted now", so the edge stays
/// and `adjCond` indexes the expression forbidding it. The header grew from 24
/// bytes to 32 to carry the condition blob's size — still a multiple of 8, so
/// the f64 block behind it stays aligned.
///
/// **Every stored graph has to be rebuilt** on each of these, deliberately. A
/// v2 graph's `adjTime` was computed without signal delay, so reading one as a
/// v3 would give routes whose cost silently disagrees with every route planned
/// since — a difference no field in the file would reveal. A v3 read as a v4
/// is worse still: it has no split junctions, so every turn restriction in the
/// city silently fails to apply and the routes look entirely reasonable while
/// being illegal to follow. Refusing is the only honest option.
const int kGraphFormatVersion = 4;

/// Header flag: the payload carries `splitParent`.
///
/// Public because it is part of the on-disk contract, and because the
/// deserializer is a separate library that has to read the same bit.
const int kGraphFlagHasSplitParent = 1 << 0;

/// Header flag: the payload carries `adjCond` and a condition blob.
const int kGraphFlagHasConditions = 1 << 1;

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

    final splitParent = g.splitParent;
    final adjCond = g.adjCond;

    final conditionBlob = adjCond == null
        ? Uint8List(0)
        : _encodeConditions(g.conditions);

    var flags = 0;
    if (splitParent != null) flags |= kGraphFlagHasSplitParent;
    if (adjCond != null) flags |= kGraphFlagHasConditions;

    // 32, not 24. An extra `int32` would have made it 28 and left every f64
    // behind it on a 4-byte boundary, where `asFloat64List` throws rather than
    // misreads — so the header grows by a whole 8.
    const header = 32;
    final f64Bytes = 8 * (3 * n + 2 * m + 2 * gp);
    final i32Bytes =
        4 * ((n + 1) + m + (m + 1) + (splitParent == null ? 0 : n));
    // adjToll and adjSignal, plus adjCond when present, one byte each per
    // edge; then the condition text.
    final u8Bytes = (adjCond == null ? 2 : 3) * m + conditionBlob.length;
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
    bd.setInt32(24, flags, Endian.little);
    bd.setInt32(28, conditionBlob.length, Endian.little);

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
    if (splitParent != null) putI32(splitParent);
    // 1-byte arrays last so the 8- and 4-byte arrays above stay aligned.
    out.setRange(off, off + g.adjToll.length, g.adjToll);
    off += g.adjToll.length;
    out.setRange(off, off + g.adjSignal.length, g.adjSignal);
    off += g.adjSignal.length;
    if (adjCond != null) {
      out.setRange(off, off + adjCond.length, adjCond);
      off += adjCond.length;
      out.setRange(off, off + conditionBlob.length, conditionBlob);
      off += conditionBlob.length;
    }

    return out;
  }

  /// Encodes the condition table: a count, then each expression length-prefixed
  /// in UTF-8. It lives inside the `.graph` payload rather than beside it, so
  /// the existing CRC covers the expressions too.
  ///
  /// Length-prefixed rather than newline-separated, which is what this was.
  /// A `restriction:conditional` value is free-form OSM text and nothing stops
  /// one containing a newline; one that did would split into two entries and
  /// shift every later index by one. The file stays self-consistent and the
  /// CRC still passes, so nothing would report it — the only symptom is that
  /// conditional turns past that point are judged against another junction's
  /// timetable. The count lets the reader refuse a table it cannot trust, and
  /// the lengths mean there is nothing left to mis-split.
  static Uint8List _encodeConditions(List<String> conditions) {
    final encoded = [for (final c in conditions) utf8.encode(c)];
    final bytes = 4 + encoded.fold<int>(0, (sum, e) => sum + 4 + e.length);

    final out = Uint8List(bytes);
    final bd = ByteData.view(out.buffer);
    bd.setInt32(0, conditions.length, Endian.little);

    var off = 4;
    for (final e in encoded) {
      bd.setInt32(off, e.length, Endian.little);
      off += 4;
      out.setRange(off, off + e.length, e);
      off += e.length;
    }
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
