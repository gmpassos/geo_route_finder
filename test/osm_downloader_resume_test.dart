import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

/// Exercises [OsmDownloader.downloadUrl] resume/caching against a tiny raw HTTP
/// server that honours `ETag`, `Range` and `If-Range`, and can simulate an
/// interrupted (truncated) response by dropping the connection mid-body.
///
/// The behaviour under test: the `.dlmeta` sidecar (ETag/Last-Modified) is
/// written *before* the `.part` body finishes, so a resume can validate the
/// partial bytes via `If-Range` — appending when unchanged, restarting when the
/// remote entity changed.
///
/// A raw [ServerSocket] (rather than [HttpServer]) is used so the test controls
/// every byte on the wire, including a clean mid-body connection drop.
class _FakeOsmServer {
  late final ServerSocket _socket;
  final List<int> body;

  /// Current entity validator served in the `ETag` header.
  String etag = '"v1"';

  /// When non-null, a *full* (non-ranged) response declares the full length but
  /// sends only this many bytes, then drops the connection — an interruption.
  int? truncateAt;

  // Observations from the most recent request.
  String? lastRange;
  String? lastIfRange;
  int? lastStatus;

  _FakeOsmServer(this.body);

  static Future<_FakeOsmServer> start(List<int> body) async {
    final server = _FakeOsmServer(body);
    server._socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server._socket.listen(server._handle);
    return server;
  }

  String get url => 'http://127.0.0.1:${_socket.port}/extract.osm.pbf';

  Future<void> close() => _socket.close();

  void _handle(Socket sock) {
    final buffer = BytesBuilder();
    sock.listen((data) {
      buffer.add(data);
      final bytes = buffer.toBytes();
      final headEnd = _indexOfCRLFCRLF(bytes);
      if (headEnd < 0) return; // headers not complete yet

      final lines = String.fromCharCodes(
        bytes.sublist(0, headEnd),
      ).split('\r\n');
      lastRange = _header(lines, 'range');
      lastIfRange = _header(lines, 'if-range');

      var start = 0;
      var serveRange = false;
      final range = lastRange;
      if (range != null && range.startsWith('bytes=')) {
        start = int.parse(range.substring('bytes='.length).split('-').first);
        serveRange = true;
      }
      // A stale `If-Range` validator forces a full response.
      if (serveRange && lastIfRange != null && lastIfRange != etag) {
        serveRange = false;
        start = 0;
      }

      final slice = body.sublist(start);

      // Interrupted full download: declare the full length, send fewer bytes,
      // then drop the connection.
      if (truncateAt != null && !serveRange) {
        lastStatus = 200;
        sock.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'ETag: $etag\r\n'
            'Content-Length: ${slice.length}\r\n'
            'Connection: close\r\n\r\n',
          ),
        );
        sock.add(slice.sublist(0, truncateAt!));
        sock.flush().then((_) => sock.destroy());
        return;
      }

      final header = StringBuffer();
      if (serveRange) {
        lastStatus = 206;
        header.write('HTTP/1.1 206 Partial Content\r\n');
        header.write(
          'Content-Range: bytes $start-${body.length - 1}/${body.length}\r\n',
        );
      } else {
        lastStatus = 200;
        header.write('HTTP/1.1 200 OK\r\n');
      }
      header.write('ETag: $etag\r\n');
      header.write('Content-Length: ${slice.length}\r\n');
      header.write('Connection: close\r\n\r\n');
      sock.add(utf8.encode(header.toString()));
      sock.add(slice);
      sock.flush().then((_) => sock.close());
    });
  }

  static int _indexOfCRLFCRLF(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static String? _header(List<String> lines, String name) {
    for (final line in lines) {
      final colon = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == name) {
        return line.substring(colon + 1).trim();
      }
    }
    return null;
  }
}

void main() {
  group('OsmDownloader resume & .dlmeta', () {
    late _FakeOsmServer server;
    late Directory outDir;
    final fullBody = List<int>.generate(4096, (i) => i % 256);

    setUp(() async {
      server = await _FakeOsmServer.start(fullBody);
      outDir = await Directory.systemTemp.createTemp('osm-resume-test');
    });

    tearDown(() async {
      await server.close();
      if (outDir.existsSync()) await outDir.delete(recursive: true);
    });

    OsmDownloader newDownloader() => OsmDownloader(outputDirectory: outDir);
    String pathFor(String suffix) => '${outDir.path}/extract.osm.pbf$suffix';

    test(
      'writes .dlmeta before the .part is promoted (interruption)',
      () async {
        server.truncateAt = 1024;
        final downloader = newDownloader();
        addTearDown(downloader.close);

        await expectLater(
          downloader.downloadUrl(server.url),
          throwsA(isA<Exception>()),
        );

        // The completed file must NOT exist, but the partial body and its
        // validators must both be on disk for a later resume.
        expect(File('${outDir.path}/extract.osm.pbf').existsSync(), isFalse);
        expect(File(pathFor('.part')).lengthSync(), 1024);

        final metaFile = File(pathFor('.dlmeta'));
        expect(metaFile.existsSync(), isTrue);
        final meta = jsonDecode(metaFile.readAsStringSync()) as Map;
        expect(meta['etag'], '"v1"');
      },
    );

    test('resumes a partial download with a matching validator', () async {
      // 1. Interrupted first attempt leaves a partial .part + .dlmeta.
      server.truncateAt = 1024;
      final d1 = newDownloader();
      await expectLater(d1.downloadUrl(server.url), throwsA(isA<Exception>()));
      d1.close();
      final partLen = File(pathFor('.part')).lengthSync();
      expect(partLen, 1024);

      // 2. Resume against a healthy server with an unchanged ETag.
      server.truncateAt = null;
      final d2 = newDownloader();
      addTearDown(d2.close);
      final dest = await d2.downloadUrl(server.url);

      // The resume sent a ranged, validated request; the server answered 206.
      expect(server.lastRange, 'bytes=$partLen-');
      expect(server.lastIfRange, '"v1"');
      expect(server.lastStatus, 206);

      // The promoted file is byte-for-byte correct and the .part is gone.
      expect(File(dest).readAsBytesSync(), fullBody);
      expect(File(pathFor('.part')).existsSync(), isFalse);
    });

    test('restarts when the validator changed (If-Range mismatch)', () async {
      // 1. Interrupted first attempt at ETag "v1".
      server.truncateAt = 1024;
      final d1 = newDownloader();
      await expectLater(d1.downloadUrl(server.url), throwsA(isA<Exception>()));
      d1.close();

      // 2. Remote changed: new ETag invalidates the cached partial.
      server.etag = '"v2"';
      server.truncateAt = null;
      final d2 = newDownloader();
      addTearDown(d2.close);
      final dest = await d2.downloadUrl(server.url);

      // If-Range carried the stale validator; the server fell back to a full
      // 200 and the download restarted from scratch.
      expect(server.lastIfRange, '"v1"');
      expect(server.lastStatus, 200);
      expect(File(dest).readAsBytesSync(), fullBody);
    });
  });
}
