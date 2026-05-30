import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/geo_node.dart';
import '../model/geo_way.dart';

/// A streaming parser for OpenStreetMap `.osm.pbf` (Protocolbuffer Binary
/// Format) files.
///
/// The parser is fully self-contained — it hand-decodes the protobuf wire format
/// and inflates zlib blocks via [ZLibCodec], so the package has no protobuf or
/// compression dependency. It is **streaming**: the file is consumed one
/// fileblock (~8k entities) at a time, so peak memory is a single decompressed
/// block regardless of file size. Country-sized extracts parse without ever
/// loading the whole file.
///
/// Entities are delivered through callbacks. Pass [readNodes]/[readWays] to skip
/// decoding entity types you do not need on a given pass (the converter uses a
/// ways-then-nodes two-pass strategy).
class OsmPbfParser {
  const OsmPbfParser();

  /// Parses [path], invoking [onNode] for every node and [onWay] for every way.
  Future<void> parse(
    String path, {
    void Function(GeoNode node)? onNode,
    void Function(GeoWay way)? onWay,
    bool readNodes = true,
    bool readWays = true,
  }) async {
    final raf = await File(path).open();
    try {
      while (true) {
        final lenBytes = await _readFully(raf, 4);
        if (lenBytes == null) break; // clean EOF
        final headerLen =
            (lenBytes[0] << 24) |
            (lenBytes[1] << 16) |
            (lenBytes[2] << 8) |
            lenBytes[3];
        final headerBytes = await _readFully(raf, headerLen);
        if (headerBytes == null) {
          throw const FormatException('truncated PBF: blob header');
        }
        final header = _parseBlobHeader(headerBytes);
        final blobBytes = await _readFully(raf, header.dataSize);
        if (blobBytes == null) {
          throw const FormatException('truncated PBF: blob');
        }
        if (header.type == 'OSMData') {
          final payload = _inflateBlob(blobBytes);
          _parsePrimitiveBlock(
            payload,
            onNode: readNodes ? onNode : null,
            onWay: readWays ? onWay : null,
          );
        }
        // OSMHeader blocks carry only bounding box / feature flags — ignored.
      }
    } finally {
      await raf.close();
    }
  }

  Future<Uint8List?> _readFully(RandomAccessFile raf, int n) async {
    if (n == 0) return Uint8List(0);
    final out = Uint8List(n);
    var read = 0;
    while (read < n) {
      final chunk = await raf.read(n - read);
      if (chunk.isEmpty) {
        return read == 0 ? null : throw const FormatException('truncated PBF');
      }
      out.setRange(read, read + chunk.length, chunk);
      read += chunk.length;
    }
    return out;
  }

  _BlobHeader _parseBlobHeader(Uint8List bytes) {
    final r = _PbfReader(bytes);
    String type = '';
    int dataSize = 0;
    while (r.hasMore) {
      final tag = r.readVarint();
      switch (tag >> 3) {
        case 1:
          type = utf8Decode(r.readLengthDelimited());
          break;
        case 3:
          dataSize = r.readVarint();
          break;
        default:
          r.skip(tag & 7);
      }
    }
    return _BlobHeader(type, dataSize);
  }

  Uint8List _inflateBlob(Uint8List bytes) {
    final r = _PbfReader(bytes);
    Uint8List? raw;
    Uint8List? zlib;
    while (r.hasMore) {
      final tag = r.readVarint();
      final field = tag >> 3;
      switch (field) {
        case 1: // raw
          raw = r.readLengthDelimited();
          break;
        case 2: // raw_size (informational)
          r.readVarint();
          break;
        case 3: // zlib_data
          zlib = r.readLengthDelimited();
          break;
        default:
          r.skip(tag & 7);
      }
    }
    if (raw != null) return raw;
    if (zlib != null) {
      return Uint8List.fromList(ZLibCodec().decode(zlib));
    }
    throw const FormatException('unsupported or empty Blob compression');
  }

  void _parsePrimitiveBlock(
    Uint8List payload, {
    void Function(GeoNode)? onNode,
    void Function(GeoWay)? onWay,
  }) {
    final r = _PbfReader(payload);
    Uint8List? stringTableBytes;
    final groups = <Uint8List>[];
    int granularity = 100;
    int latOffset = 0;
    int lonOffset = 0;

    while (r.hasMore) {
      final tag = r.readVarint();
      final field = tag >> 3;
      switch (field) {
        case 1:
          stringTableBytes = r.readLengthDelimited();
          break;
        case 2:
          groups.add(r.readLengthDelimited());
          break;
        case 17:
          granularity = r.readVarint();
          break;
        case 19:
          latOffset = r.readVarint();
          break;
        case 20:
          lonOffset = r.readVarint();
          break;
        default:
          r.skip(tag & 7);
      }
    }

    final strings = stringTableBytes == null
        ? const <String>[]
        : _parseStringTable(stringTableBytes);

    for (final group in groups) {
      _parseGroup(
        group,
        strings,
        granularity,
        latOffset,
        lonOffset,
        onNode: onNode,
        onWay: onWay,
      );
    }
  }

  List<String> _parseStringTable(Uint8List bytes) {
    final r = _PbfReader(bytes);
    final out = <String>[];
    while (r.hasMore) {
      final tag = r.readVarint();
      if (tag >> 3 == 1) {
        out.add(utf8Decode(r.readLengthDelimited()));
      } else {
        r.skip(tag & 7);
      }
    }
    return out;
  }

  void _parseGroup(
    Uint8List bytes,
    List<String> strings,
    int granularity,
    int latOffset,
    int lonOffset, {
    void Function(GeoNode)? onNode,
    void Function(GeoWay)? onWay,
  }) {
    final r = _PbfReader(bytes);
    while (r.hasMore) {
      final tag = r.readVarint();
      final field = tag >> 3;
      switch (field) {
        case 2: // DenseNodes
          final dense = r.readLengthDelimited();
          if (onNode != null) {
            _parseDenseNodes(dense, granularity, latOffset, lonOffset, onNode);
          }
          break;
        case 3: // Way
          final way = r.readLengthDelimited();
          if (onWay != null) _parseWay(way, strings, onWay);
          break;
        default:
          // field 1 (non-dense nodes) and 4 (relations) are not needed.
          r.skip(tag & 7);
      }
    }
  }

  void _parseDenseNodes(
    Uint8List bytes,
    int granularity,
    int latOffset,
    int lonOffset,
    void Function(GeoNode) onNode,
  ) {
    final r = _PbfReader(bytes);
    List<int>? ids;
    List<int>? lats;
    List<int>? lons;
    while (r.hasMore) {
      final tag = r.readVarint();
      final field = tag >> 3;
      switch (field) {
        case 1:
          ids = r.readPackedSInt64();
          break;
        case 8:
          lats = r.readPackedSInt64();
          break;
        case 9:
          lons = r.readPackedSInt64();
          break;
        default:
          r.skip(tag & 7);
      }
    }
    if (ids == null || lats == null || lons == null) return;
    var id = 0;
    var lat = 0;
    var lon = 0;
    for (var i = 0; i < ids.length; i++) {
      id += ids[i];
      lat += lats[i];
      lon += lons[i];
      onNode(
        GeoNode(
          id: id,
          lat: 1e-9 * (latOffset + granularity * lat),
          lon: 1e-9 * (lonOffset + granularity * lon),
        ),
      );
    }
  }

  void _parseWay(
    Uint8List bytes,
    List<String> strings,
    void Function(GeoWay) onWay,
  ) {
    final r = _PbfReader(bytes);
    int id = 0;
    List<int>? keys;
    List<int>? vals;
    List<int>? refs;
    while (r.hasMore) {
      final tag = r.readVarint();
      final field = tag >> 3;
      switch (field) {
        case 1:
          id = r.readVarint();
          break;
        case 2:
          keys = r.readPackedVarints();
          break;
        case 3:
          vals = r.readPackedVarints();
          break;
        case 8:
          refs = r.readPackedSInt64();
          break;
        default:
          r.skip(tag & 7);
      }
    }
    if (refs == null || refs.isEmpty) return;

    final tags = <String, String>{};
    if (keys != null && vals != null) {
      final count = keys.length < vals.length ? keys.length : vals.length;
      for (var i = 0; i < count; i++) {
        final k = keys[i];
        final v = vals[i];
        if (k < strings.length && v < strings.length) {
          tags[strings[k]] = strings[v];
        }
      }
    }

    final nodeIds = <int>[];
    var ref = 0;
    for (final d in refs) {
      ref += d;
      nodeIds.add(ref);
    }
    onWay(GeoWay(id: id, nodeIds: nodeIds, tags: tags));
  }
}

class _BlobHeader {
  final String type;
  final int dataSize;
  const _BlobHeader(this.type, this.dataSize);
}

/// Minimal protobuf wire-format reader over a byte view.
class _PbfReader {
  final Uint8List _b;
  int _pos;
  final int _end;

  _PbfReader(Uint8List b) : _b = b, _pos = 0, _end = b.length;

  bool get hasMore => _pos < _end;

  int readVarint() {
    var shift = 0;
    var result = 0;
    while (true) {
      final byte = _b[_pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  /// Decodes a zigzag-encoded signed varint.
  int readSInt64() {
    final n = readVarint();
    return (n >>> 1) ^ -(n & 1);
  }

  Uint8List readLengthDelimited() {
    final len = readVarint();
    final view = Uint8List.view(_b.buffer, _b.offsetInBytes + _pos, len);
    _pos += len;
    return view;
  }

  List<int> readPackedVarints() {
    final sub = _PbfReader(readLengthDelimited());
    final out = <int>[];
    while (sub.hasMore) {
      out.add(sub.readVarint());
    }
    return out;
  }

  List<int> readPackedSInt64() {
    final sub = _PbfReader(readLengthDelimited());
    final out = <int>[];
    while (sub.hasMore) {
      out.add(sub.readSInt64());
    }
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
        break;
      case 1:
        _pos += 8;
        break;
      case 2:
        _pos += readVarint();
        break;
      case 5:
        _pos += 4;
        break;
      default:
        throw FormatException('unknown wire type $wireType');
    }
  }
}

/// UTF-8 decode helper kept here to avoid importing dart:convert across the
/// hot parse path (the table-driven decode is allocation-light for ASCII tags).
String utf8Decode(Uint8List bytes) {
  // Fast path for pure ASCII (the overwhelming majority of OSM tag strings).
  var ascii = true;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return String.fromCharCodes(bytes);
  return const Utf8Decoder().convert(bytes);
}
