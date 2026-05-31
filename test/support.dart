import 'dart:io';
import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';

/// Builds an `n x n` grid graph of bidirectional [speedKmh] roads spaced
/// [step] degrees apart, anchored near São Paulo. Shared across routing,
/// spatial and serialization tests.
GeoGraph buildGrid({
  int n = 12,
  double step = 0.01,
  double speedKmh = 50,
  double originLat = -23.5,
  double originLon = -46.7,
}) {
  final nodes = <GeoNode>[];
  final edges = <GeoEdge>[];
  int id(int r, int c) => r * n + c;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      nodes.add(
        GeoNode(
          id: id(r, c),
          lat: originLat + r * step,
          lon: originLon + c * step,
        ),
      );
    }
  }
  GeoEdge road(int a, int b) => GeoEdge(
    sourceId: a,
    targetId: b,
    distanceMeters: nodes[a].coordinate.distanceTo(nodes[b].coordinate),
    speedKmh: speedKmh,
  );
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (c + 1 < n) edges.add(road(id(r, c), id(r, c + 1)));
      if (r + 1 < n) edges.add(road(id(r, c), id(r + 1, c)));
    }
  }
  return GeoGraph(nodes: nodes, edges: edges);
}

/// An in-memory [GeoStorage] (generic-graph only) used to exercise the
/// non-compiled fallback path in routers.
class MemoryStorage implements GeoStorage {
  final Map<String, GeoGraph> _store = {};

  String _key(String id, VehicleProfile profile) => '${id}_${profile.name}';

  @override
  Future<void> saveGraph(
    String id,
    GeoGraph graph, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => _store[_key(id, profile)] = graph;

  @override
  Future<GeoGraph?> loadGraph(
    String id, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => _store[_key(id, profile)];

  @override
  Future<bool> exists(
    String id, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => _store.containsKey(_key(id, profile));

  @override
  Future<void> delete(
    String id, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => _store.remove(_key(id, profile));
}

/// Encodes a minimal `.osm.pbf` with three dense nodes and a single way carrying
/// [tags]. Used to drive the parser/converter through a real, byte-for-byte file
/// while choosing the way's tags (highway class, oneway, toll, …) per test.
///
/// One PrimitiveBlock, one PrimitiveGroup; the blob is stored raw unless
/// [compress] requests zlib (the parser supports both).
Uint8List buildWayPbf({
  required Map<String, String> tags,
  List<int> nodeIds = const [1, 2, 3],
  List<double> lats = const [-23.5, -23.49, -23.49],
  List<double> lons = const [-46.7, -46.7, -46.69],
  bool compress = false,
}) {
  int latVal(double deg) => (deg / 1e-7).round();

  // String table: index 0 is the required empty string; intern keys and values.
  final strings = <String>[''];
  final indexOf = <String, int>{};
  int intern(String s) =>
      indexOf.putIfAbsent(s, () => (strings..add(s)).length - 1);
  final wayKeys = <int>[];
  final wayVals = <int>[];
  tags.forEach((k, v) {
    wayKeys.add(intern(k));
    wayVals.add(intern(v));
  });

  final block = _primitiveBlock(
    strings: strings,
    nodeIds: nodeIds,
    lats: [for (final v in lats) latVal(v)],
    lons: [for (final v in lons) latVal(v)],
    wayId: 10,
    wayKeys: wayKeys,
    wayVals: wayVals,
    wayRefs: nodeIds,
  );

  // Blob: field 1 raw, or field 2 raw_size + field 3 zlib_data.
  final blob = BytesBuilder();
  if (compress) {
    final z = ZLibCodec().encode(block);
    _writeVarint(blob, (2 << 3));
    _writeVarint(blob, block.length);
    _writeBytes(blob, 3, Uint8List.fromList(z));
  } else {
    _writeBytes(blob, 1, block);
  }
  final blobBytes = blob.toBytes();

  // BlobHeader: field 1 type, field 3 datasize.
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

/// Writes [bytes] to a fresh temporary `.osm.pbf` file and returns its path. The
/// caller is responsible for deleting the parent directory.
String writeTempPbf(Uint8List bytes) {
  final dir = Directory.systemTemp.createTempSync('grf_pbf_');
  final file = File('${dir.path}/sample.osm.pbf');
  file.writeAsBytesSync(bytes);
  return file.path;
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
  final st = BytesBuilder();
  for (final s in strings) {
    _writeBytes(st, 1, Uint8List.fromList(s.codeUnits));
  }

  final dense = BytesBuilder();
  _writePackedSInt(dense, 1, _delta(nodeIds));
  _writePackedSInt(dense, 8, _delta(lats));
  _writePackedSInt(dense, 9, _delta(lons));

  final way = BytesBuilder();
  _writeVarint(way, (1 << 3));
  _writeVarint(way, wayId);
  _writePackedVarint(way, 2, wayKeys);
  _writePackedVarint(way, 3, wayVals);
  _writePackedSInt(way, 8, _delta(wayRefs));

  final group = BytesBuilder();
  _writeBytes(group, 2, dense.toBytes());
  _writeBytes(group, 3, way.toBytes());

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
