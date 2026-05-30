import 'dart:io';

/// The result of probing a single mirror [Uri].
///
/// Carries enough signal to rank mirrors against each other ([available],
/// [latency], [throughputBytesPerSecond]) plus a [probedAt]/[ttl] pair so the
/// registry can cache and expire results.
class MirrorProbe {
  /// The probed URL.
  final Uri uri;

  /// Whether the mirror responded successfully (HTTP < 400, no error/timeout).
  final bool available;

  /// Time to first response headers (a HEAD round-trip). Lower is better.
  final Duration latency;

  /// Measured download throughput in bytes/second from a small sample, or `0`
  /// when not measured. Higher is better.
  final double throughputBytesPerSecond;

  /// `Content-Length` reported by the server, if any.
  final int? contentLength;

  /// When this probe was taken.
  final DateTime probedAt;

  /// How long this probe stays valid in a cache.
  final Duration ttl;

  MirrorProbe({
    required this.uri,
    required this.available,
    this.latency = Duration.zero,
    this.throughputBytesPerSecond = 0,
    this.contentLength,
    DateTime? probedAt,
    this.ttl = const Duration(minutes: 30),
  }) : probedAt = probedAt ?? DateTime.now();

  /// A probe representing an unreachable or failing mirror.
  factory MirrorProbe.unavailable(
    Uri uri, {
    Duration ttl = const Duration(minutes: 30),
  }) => MirrorProbe(uri: uri, available: false, ttl: ttl);

  /// Whether this cached probe has outlived its [ttl].
  bool get isExpired => DateTime.now().difference(probedAt) >= ttl;

  @override
  String toString() => available
      ? 'MirrorProbe($uri, ${latency.inMilliseconds}ms, '
            '${throughputBytesPerSecond.toStringAsFixed(0)} B/s)'
      : 'MirrorProbe($uri, unavailable)';
}

/// Probes a mirror [Uri] and returns its [MirrorProbe]. This is the seam used
/// by [OsmDownloadSourceRegistry]; tests can inject a deterministic prober.
typedef MirrorProber = Future<MirrorProbe> Function(Uri uri);

/// Measures mirror availability, latency and throughput over real HTTP.
///
/// * **Availability + latency** come from a `HEAD` request (time to response
///   headers).
/// * **Throughput** comes from a small ranged `GET` of the first [sampleBytes]
///   bytes, timed end-to-end.
///
/// Use [probe] directly, or pass it as a [MirrorProber] to the registry.
class MirrorBenchmark {
  final HttpClient _client;
  final bool _ownsClient;

  /// Per-request timeout for HEAD and the throughput sample.
  final Duration timeout;

  /// Number of bytes to download when estimating throughput. `0` disables the
  /// throughput sample (availability + latency only).
  final int sampleBytes;

  /// TTL stamped onto every produced [MirrorProbe].
  final Duration probeTtl;

  MirrorBenchmark({
    HttpClient? client,
    this.timeout = const Duration(seconds: 10),
    this.sampleBytes = 256 * 1024,
    this.probeTtl = const Duration(minutes: 30),
  }) : _client = client ?? HttpClient(),
       _ownsClient = client == null;

  /// Probes [uri]. Never throws: failures (HTTP >= 400, connection errors,
  /// timeouts) are reported as an unavailable [MirrorProbe].
  Future<MirrorProbe> probe(Uri uri) async {
    final sw = Stopwatch()..start();
    try {
      final headReq = await _client.openUrl('HEAD', uri).timeout(timeout);
      final headResp = await headReq.close().timeout(timeout);
      final latency = sw.elapsed;
      await headResp.drain<void>();

      if (headResp.statusCode >= 400) {
        return MirrorProbe.unavailable(uri, ttl: probeTtl);
      }

      final reportedLen = headResp.headers.contentLength;
      final contentLength = reportedLen >= 0 ? reportedLen : null;

      var throughput = 0.0;
      if (sampleBytes > 0) {
        throughput = await _measureThroughput(uri);
      }

      return MirrorProbe(
        uri: uri,
        available: true,
        latency: latency,
        throughputBytesPerSecond: throughput,
        contentLength: contentLength,
        ttl: probeTtl,
      );
    } catch (_) {
      return MirrorProbe.unavailable(uri, ttl: probeTtl);
    }
  }

  Future<double> _measureThroughput(Uri uri) async {
    final sw = Stopwatch()..start();
    final req = await _client.getUrl(uri).timeout(timeout);
    req.headers.add(HttpHeaders.rangeHeader, 'bytes=0-${sampleBytes - 1}');
    final resp = await req.close().timeout(timeout);
    var bytes = 0;
    // Reading enough of the stream then `break`ing cancels the subscription,
    // which closes the connection — fine for a throughput sample.
    await for (final chunk in resp) {
      bytes += chunk.length;
      if (bytes >= sampleBytes) break;
    }
    sw.stop();
    final seconds = sw.elapsedMicroseconds / 1e6;
    if (seconds <= 0 || bytes == 0) return 0;
    return bytes / seconds;
  }

  /// Releases the underlying [HttpClient] if this instance created it.
  void close() {
    if (_ownsClient) _client.close(force: true);
  }
}
