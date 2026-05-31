import 'dart:io';
import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('Crc32', () {
    test('matches the canonical check value', () {
      // CRC-32 of "123456789" is 0xCBF43926.
      final bytes = Uint8List.fromList('123456789'.codeUnits);
      expect(Crc32.compute(bytes), 0xCBF43926);
    });
  });

  group('graph serialization', () {
    final graph = const GraphBuilder().build(buildGrid(n: 8));

    test('round-trips a routing graph exactly', () {
      final bytes = const GraphSerializer().serializeGraph(graph);
      final back = const GraphDeserializer().deserializeGraph(bytes);
      expect(back.nodeCount, graph.nodeCount);
      expect(back.edgeCount, graph.edgeCount);
      expect(back.lat, graph.lat);
      expect(back.lon, graph.lon);
      expect(back.adjOffset, graph.adjOffset);
      expect(back.adjTarget, graph.adjTarget);
      expect(back.adjTime, graph.adjTime);
      expect(back.adjDist, graph.adjDist);
      expect(back.adjToll, graph.adjToll);
      expect(back.geomOffset, graph.geomOffset);
      expect(back.geomCoords, graph.geomCoords);
    });

    test('round-trips per-edge toll flags', () {
      // A 3-node chain whose single original edge is a toll road.
      final nodes = [
        for (var i = 0; i < 3; i++) GeoNode(id: i, lat: 0, lon: i * 0.001),
      ];
      final edges = [
        for (var i = 0; i < 2; i++)
          GeoEdge(
            sourceId: i,
            targetId: i + 1,
            distanceMeters: 111,
            speedKmh: 50,
            tolls: 1,
          ),
      ];
      final tolled = const GraphBuilder().build(
        GeoGraph(nodes: nodes, edges: edges),
      );
      final bytes = const GraphSerializer().serializeGraph(tolled);
      final back = const GraphDeserializer().deserializeGraph(bytes);
      expect(back.adjToll, tolled.adjToll);
      expect(back.adjToll.any((t) => t != 0), isTrue);
    });

    test('serialization is deterministic', () {
      final a = const GraphSerializer().serializeGraph(graph);
      final b = const GraphSerializer().serializeGraph(graph);
      expect(a, b);
    });

    test('round-trips the KD-tree index', () {
      final tree = KdTree.build(graph);
      final bytes = const GraphSerializer().serializeIndex(tree);
      final back = const GraphDeserializer().deserializeIndex(bytes, graph);
      expect(back.order, tree.order);
      expect(back.cosRef, tree.cosRef);
      // The rebuilt tree gives identical nearest results.
      final a = tree.findNearest(-23.45, -46.65);
      final b = back.findNearest(-23.45, -46.65);
      expect(b.node, a.node);
    });

    test('rejects a corrupt magic', () {
      final bytes = const GraphSerializer().serializeGraph(graph);
      bytes[0] = 0;
      expect(
        () => const GraphDeserializer().deserializeGraph(bytes),
        throwsA(isA<GraphFormatException>()),
      );
    });
  });

  group('LocalFileStorage', () {
    late Directory dir;
    late LocalFileStorage storage;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('grf_storage_');
      storage = LocalFileStorage(directory: dir.path);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('saveGraph / loadCompiled round-trip', () async {
      await storage.saveGraph('city', buildGrid(n: 6));
      expect(await storage.exists('city'), isTrue);
      final compiled = await storage.loadCompiled('city');
      expect(compiled, isNotNull);
      expect(compiled!.graph.nodeCount, 36);
      // Files exist on disk.
      expect(File('${dir.path}/city.graph').existsSync(), isTrue);
      expect(File('${dir.path}/city.index').existsSync(), isTrue);
      expect(File('${dir.path}/city.meta').existsSync(), isTrue);
    });

    test('delete removes all artifacts', () async {
      await storage.saveGraph('tmp', buildGrid(n: 4));
      await storage.delete('tmp');
      expect(await storage.exists('tmp'), isFalse);
      expect(File('${dir.path}/tmp.graph').existsSync(), isFalse);
    });

    test('detects a corrupted .graph via checksum', () async {
      await storage.saveGraph('city', buildGrid(n: 4));
      final f = File('${dir.path}/city.graph');
      final bytes = await f.readAsBytes();
      bytes[bytes.length - 1] ^= 0xFF; // flip a data byte
      await f.writeAsBytes(bytes, flush: true);
      expect(
        () => storage.loadCompiled('city'),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('missing graph loads as null', () async {
      expect(await storage.loadCompiled('nope'), isNull);
      expect(await storage.loadGraph('nope'), isNull);
    });
  });
}
