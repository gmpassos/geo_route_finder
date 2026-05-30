import 'dart:io';
import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

/// Minimal `.osm.pbf` encoder used to drive the parser through a real, byte-for-
/// byte file. Encodes one PrimitiveBlock with three dense nodes and one way.
Uint8List buildPbf({required bool compress}) {
  int latVal(double deg) => (deg / 1e-7).round();

  final block = _primitiveBlock(
    strings: ['', 'highway', 'residential', 'oneway', 'yes'],
    nodeIds: const [1, 2, 3],
    lats: [latVal(-23.5), latVal(-23.49), latVal(-23.49)],
    lons: [latVal(-46.7), latVal(-46.7), latVal(-46.69)],
    wayId: 10,
    wayKeys: const [1, 3], // highway, oneway
    wayVals: const [2, 4], // residential, yes
    wayRefs: const [1, 2, 3],
  );

  // Blob: field 1 raw, or field 3 zlib_data.
  final blob = BytesBuilder();
  if (compress) {
    final z = ZLibCodec().encode(block);
    _writeVarint(blob, (2 << 3)); // field 2 raw_size
    _writeVarint(blob, block.length);
    _writeBytes(blob, 3, Uint8List.fromList(z));
  } else {
    _writeBytes(blob, 1, block);
  }
  final blobBytes = blob.toBytes();

  // BlobHeader: field1 type, field3 datasize.
  final header = BytesBuilder();
  _writeBytes(header, 1, Uint8List.fromList('OSMData'.codeUnits));
  _writeVarint(header, (3 << 3));
  _writeVarint(header, blobBytes.length);
  final headerBytes = header.toBytes();

  final out = BytesBuilder();
  final len = headerBytes.length;
  out.add([
    (len >> 24) & 0xFF,
    (len >> 16) & 0xFF,
    (len >> 8) & 0xFF,
    len & 0xFF,
  ]);
  out.add(headerBytes);
  out.add(blobBytes);
  return out.toBytes();
}

Uint8List _primitiveBlock({
  required List<String> strings,
  required List<int> nodeIds,
  required List<int> lats,
  required List<int> lons,
  required int wayId,
  required List<int> wayKeys,
  required List<int> wayVals,
  required List<int> wayRefs,
}) {
  // StringTable (field 1): repeated bytes s (field 1).
  final st = BytesBuilder();
  for (final s in strings) {
    _writeBytes(st, 1, Uint8List.fromList(s.codeUnits));
  }

  // DenseNodes (field 2 of group): ids(1), lats(8), lons(9) packed sint64.
  final dense = BytesBuilder();
  _writePackedSInt(dense, 1, _delta(nodeIds));
  _writePackedSInt(dense, 8, _delta(lats));
  _writePackedSInt(dense, 9, _delta(lons));

  // Way (field 3 of group).
  final way = BytesBuilder();
  _writeVarint(way, (1 << 3));
  _writeVarint(way, wayId);
  _writePackedVarint(way, 2, wayKeys);
  _writePackedVarint(way, 3, wayVals);
  _writePackedSInt(way, 8, _delta(wayRefs));

  // PrimitiveGroup: field 2 dense, field 3 way.
  final group = BytesBuilder();
  _writeBytes(group, 2, dense.toBytes());
  _writeBytes(group, 3, way.toBytes());

  // PrimitiveBlock: field 1 stringtable, field 2 group.
  final block = BytesBuilder();
  _writeBytes(block, 1, st.toBytes());
  _writeBytes(block, 2, group.toBytes());
  return block.toBytes();
}

List<int> _delta(List<int> values) {
  final out = <int>[];
  var prev = 0;
  for (final v in values) {
    out.add(v - prev);
    prev = v;
  }
  return out;
}

void _writeVarint(BytesBuilder b, int value) {
  var v = value;
  while (true) {
    final byte = v & 0x7f;
    v >>>= 7;
    if (v != 0) {
      b.addByte(byte | 0x80);
    } else {
      b.addByte(byte);
      break;
    }
  }
}

int _zigzag(int n) => (n << 1) ^ (n >> 63);

void _writeBytes(BytesBuilder b, int field, Uint8List bytes) {
  _writeVarint(b, (field << 3) | 2);
  _writeVarint(b, bytes.length);
  b.add(bytes);
}

void _writePackedVarint(BytesBuilder b, int field, List<int> values) {
  final sub = BytesBuilder();
  for (final v in values) {
    _writeVarint(sub, v);
  }
  _writeBytes(b, field, sub.toBytes());
}

void _writePackedSInt(BytesBuilder b, int field, List<int> values) {
  final sub = BytesBuilder();
  for (final v in values) {
    _writeVarint(sub, _zigzag(v));
  }
  _writeBytes(b, field, sub.toBytes());
}

void main() {
  for (final compress in [false, true]) {
    group('OsmPbfParser (${compress ? 'zlib' : 'raw'})', () {
      late File file;

      setUp(() {
        final dir = Directory.systemTemp.createTempSync('grf_pbf_');
        file = File('${dir.path}/sample.osm.pbf');
        file.writeAsBytesSync(buildPbf(compress: compress));
      });

      tearDown(() => file.parent.deleteSync(recursive: true));

      test('decodes nodes with correct coordinates', () async {
        final nodes = <GeoNode>[];
        await const OsmPbfParser().parse(file.path, onNode: nodes.add);
        expect(nodes.length, 3);
        expect(nodes[0].id, 1);
        expect(nodes[0].lat, closeTo(-23.5, 1e-7));
        expect(nodes[0].lon, closeTo(-46.7, 1e-7));
        expect(nodes[2].lon, closeTo(-46.69, 1e-7));
      });

      test('decodes ways with tags and refs', () async {
        final ways = <GeoWay>[];
        await const OsmPbfParser().parse(file.path, onWay: ways.add);
        expect(ways.length, 1);
        expect(ways[0].id, 10);
        expect(ways[0].nodeIds, [1, 2, 3]);
        expect(ways[0].tags['highway'], 'residential');
        expect(ways[0].tags['oneway'], 'yes');
      });

      test('OsmConverter builds a routable graph', () async {
        final geo = await OsmConverter().toGeoGraph(file.path);
        expect(geo.nodes.length, 3);
        // 2 segments, one-way -> 2 directed edges.
        expect(geo.edges.length, 2);
        expect(geo.edges.every((e) => e.oneWay), isTrue);
        expect(
          geo.edges.first.speedKmh,
          OsmConverter.defaultSpeedKmh['residential'],
        );
      });
    });
  }
}
