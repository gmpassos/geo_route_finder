import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'download/osm_download_source.dart';
import 'download/osm_download_source_registry.dart';

/// Progress callback: [received] bytes so far, [total] bytes expected (or `null`
/// when the server does not report a length), and the [url] being downloaded.
typedef DownloadProgress = void Function(int received, int? total, String url);

/// Downloads OpenStreetMap extracts — fully source-agnostic.
///
/// The downloader contains **no** provider-specific URL logic. All region →
/// URL mapping lives behind an [OsmSourceResolver] (an
/// [OsmDownloadSourceRegistry] by default), so new providers and mirrors are
/// added without touching this class. Features:
///
/// * **Automatic source selection**: [downloadRegion] asks the resolver for
///   candidate URLs and downloads from the first that works.
/// * **Fallback**: if a candidate fails (HTTP error, timeout, unavailable
///   server) the next candidate is tried automatically.
/// * **Resumable** downloads via HTTP `Range` requests (a `.part` file holds the
///   in-progress bytes and is promoted on success).
/// * **HTTP caching** with `ETag`/`Last-Modified`, stored in a `.dlmeta`
///   sidecar; an unchanged remote returns `304` and the local file is reused.
/// * **Size verification** against `Content-Length`/`Content-Range`.
/// * **Progress reporting** through [DownloadProgress].
class OsmDownloader {
  /// Resolves region identifiers into ordered candidate download URLs.
  final OsmSourceResolver sourceResolver;

  /// Directory into which files are written.
  final Directory outputDirectory;

  final HttpClient _client;

  OsmDownloader({
    OsmSourceResolver? sourceResolver,
    Directory? outputDirectory,
    HttpClient? client,
  }) : sourceResolver =
           sourceResolver ?? OsmDownloadSourceRegistry.withDefaults(),
       _client = client ?? HttpClient(),
       outputDirectory =
           outputDirectory ??
           Directory(p.join(Directory.current.path, 'osm-cache'));

  /// Downloads the extract for [region] (e.g. `south-america/brazil/sao-paulo`)
  /// and returns the path to the completed file.
  ///
  /// The [sourceResolver] resolves the region into an ordered list of candidate
  /// URLs; each is attempted in turn until one succeeds. Throws an
  /// [OsmSourceException] when no source can serve the region or when every
  /// candidate fails.
  Future<String> downloadRegion({
    required String region,
    DownloadProgress? onProgress,
    bool resume = true,
  }) async {
    final candidates = await sourceResolver.resolveCandidates(region);
    if (candidates.isEmpty) {
      throw OsmSourceException(
        'No download source can serve region "$region".',
      );
    }

    Object? lastError;
    for (final candidate in candidates) {
      try {
        return await downloadUrl(
          candidate.uri.toString(),
          onProgress: onProgress,
          resume: resume,
        );
      } catch (e) {
        // HTTP error, timeout, unavailable server, … — fall back to the next
        // candidate source/mirror.
        lastError = e;
      }
    }

    throw OsmSourceException(
      'All ${candidates.length} candidate source(s) failed for region '
      '"$region".',
      cause: lastError,
    );
  }

  /// Downloads an arbitrary [url] to [fileName] (defaulting to the URL's last
  /// path segment) under [outputDirectory]. Returns the completed file path.
  Future<String> downloadUrl(
    String url, {
    String? fileName,
    DownloadProgress? onProgress,
    bool resume = true,
  }) async {
    await outputDirectory.create(recursive: true);
    final name = fileName ?? Uri.parse(url).pathSegments.last;
    final dest = p.join(outputDirectory.path, name);
    final partPath = '$dest.part';
    final metaPath = '$dest.dlmeta';

    final destFile = File(dest);
    final partFile = File(partPath);

    final cache = await _readCache(metaPath);
    var existing = resume && await partFile.exists()
        ? await partFile.length()
        : 0;

    final request = await _client.getUrl(Uri.parse(url));
    // Conditional GET when we already hold a complete copy.
    if (await destFile.exists() && cache != null) {
      if (cache.etag != null) {
        request.headers.add(HttpHeaders.ifNoneMatchHeader, cache.etag!);
      } else if (cache.lastModified != null) {
        request.headers.add(
          HttpHeaders.ifModifiedSinceHeader,
          cache.lastModified!,
        );
      }
    }
    if (existing > 0) {
      request.headers.add(HttpHeaders.rangeHeader, 'bytes=$existing-');
      // Validate the partial bytes against the remote resource: with `If-Range`
      // the server replies 206 only when the validator still matches, otherwise
      // it sends a full 200 (handled below by restarting the download). The
      // validator comes from the `.dlmeta` written when the partial was started.
      final validator = cache?.etag ?? cache?.lastModified;
      if (validator != null) {
        request.headers.add(HttpHeaders.ifRangeHeader, validator);
      }
    }

    final response = await request.close();

    if (response.statusCode == HttpStatus.notModified) {
      await response.drain<void>();
      return dest; // local copy is current
    }

    final bool partial = response.statusCode == HttpStatus.partialContent;
    if (response.statusCode != HttpStatus.ok && !partial) {
      await response.drain<void>();
      throw HttpException(
        'Download failed (${response.statusCode}) for $url',
        uri: Uri.parse(url),
      );
    }

    // A 200 to a ranged request means the server ignored the range (or the
    // `If-Range` validator no longer matches): start over.
    if (!partial) existing = 0;

    // Persist the validators *before* streaming the body, so an interrupted
    // download leaves a `.dlmeta` that a later resume can use to verify the
    // `.part` bytes via `If-Range`. (Best effort: skipped when the server sends
    // neither `ETag` nor `Last-Modified`; any earlier `.dlmeta` is kept.)
    await _writeCache(metaPath, response.headers);

    final reportedLen = response.headers.contentLength;
    final int? total = reportedLen >= 0 ? existing + reportedLen : null;

    final sink = partFile.openWrite(
      mode: existing > 0 ? FileMode.append : FileMode.write,
    );
    var received = existing;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null) onProgress(received, total, url);
      }
    } finally {
      await sink.close();
    }

    if (total != null && received != total) {
      throw HttpException(
        'Size mismatch for $url: got $received, expected $total',
        uri: Uri.parse(url),
      );
    }

    if (await destFile.exists()) await destFile.delete();
    await partFile.rename(dest);
    return dest;
  }

  Future<_DownloadCache?> _readCache(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return _DownloadCache(
        etag: j['etag'] as String?,
        lastModified: j['lastModified'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String path, HttpHeaders headers) async {
    final etag = headers.value(HttpHeaders.etagHeader);
    final lastModified = headers.value(HttpHeaders.lastModifiedHeader);
    if (etag == null && lastModified == null) return;
    await File(
      path,
    ).writeAsString(jsonEncode({'etag': etag, 'lastModified': lastModified}));
  }

  /// Releases the underlying HTTP client. Call when the downloader is no longer
  /// needed.
  void close() => _client.close(force: true);
}

class _DownloadCache {
  final String? etag;
  final String? lastModified;

  const _DownloadCache({this.etag, this.lastModified});
}
