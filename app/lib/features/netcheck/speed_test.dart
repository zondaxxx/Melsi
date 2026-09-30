// Single-connection throughput test against Cloudflare's speed endpoints.
//
// Download streams a large body and counts bytes as they arrive; upload
// pushes random 64 KB chunks and counts bytes as the socket accepts them.
// Both emit a [SpeedSample] on a fixed cadence (so a stalled link shows a
// falling number rather than a frozen one) and stop at a time cap. The
// endpoints are in `ConfigBuilder.probeHosts`, so while connected the test
// measures the tunnel under every routing preset.

import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;

/// One progress reading: total [bytes] so far, [elapsed] since the request
/// started and the instantaneous [bps] over the last interval.
class SpeedSample {
  const SpeedSample({required this.bytes, required this.elapsed, required this.bps});

  final int bytes;
  final Duration elapsed;

  /// Bytes per second over the interval that ended with this sample.
  final double bps;

  /// Bytes per second averaged over the whole run so far.
  double get averageBps =>
      elapsed.inMicroseconds == 0 ? 0 : bytes * 1e6 / elapsed.inMicroseconds;

  @override
  String toString() => 'SpeedSample($bytes B, ${elapsed.inMilliseconds} ms, $bps B/s)';
}

class SpeedTest {
  SpeedTest({
    required http.Client Function() client,
    Uri? downloadUrl,
    Uri? uploadUrl,
    this.cap = const Duration(seconds: 8),
    this.uploadCap = const Duration(seconds: 6),
    this.interval = const Duration(milliseconds: 250),
    Random? random,
  })  : _newClient = client,
        downloadUrl = downloadUrl ?? defaultDownloadUrl,
        uploadUrl = uploadUrl ?? defaultUploadUrl,
        _random = random ?? Random();

  static final Uri defaultDownloadUrl =
      Uri.parse('https://speed.cloudflare.com/__down?bytes=50000000');
  static final Uri defaultUploadUrl = Uri.parse('https://speed.cloudflare.com/__up');

  /// Upload chunk size.
  static const int chunkSize = 64 << 10;

  final http.Client Function() _newClient;
  final Uri downloadUrl;
  final Uri uploadUrl;

  /// Longest a download runs before the stream completes.
  final Duration cap;

  /// Longest an upload pushes data.
  final Duration uploadCap;

  /// Sampling cadence.
  final Duration interval;
  final Random _random;

  http.Client? _client;
  void Function()? _abort;
  bool _cancelled = false;

  /// True once [cancel] was called; a run that ends afterwards is void.
  bool get cancelled => _cancelled;

  /// Stops whatever is running and closes the client, which aborts the
  /// socket. The active stream completes (without error) shortly after.
  void cancel() {
    _cancelled = true;
    _abort?.call();
    _client?.close();
    _client = null;
  }

  /// Streams download progress every [interval] until [cap] or EOF.
  Stream<SpeedSample> download() {
    final ctrl = StreamController<SpeedSample>();
    ctrl.onListen = () => _runDownload(ctrl);
    return ctrl.stream;
  }

  /// Streams upload progress every [interval] until [bytes] were sent or
  /// [uploadCap] elapsed.
  Stream<SpeedSample> upload({int bytes = 5 << 20}) {
    final ctrl = StreamController<SpeedSample>();
    ctrl.onListen = () => _runUpload(ctrl, bytes);
    return ctrl.stream;
  }

  Future<void> _runDownload(StreamController<SpeedSample> ctrl) async {
    final client = _client = _newClient();
    final meter = _Meter(ctrl, interval);
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _abort = finish;
    StreamSubscription<List<int>>? sub;
    Timer? capTimer;
    try {
      final res = await client.send(http.Request('GET', downloadUrl));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw http.ClientException('HTTP ${res.statusCode}', downloadUrl);
      }
      meter.start();
      capTimer = Timer(cap, finish);
      sub = res.stream.listen(
        (chunk) => meter.bytes += chunk.length,
        onError: (Object e, StackTrace st) {
          if (!done.isCompleted) done.completeError(e, st);
        },
        onDone: finish,
        cancelOnError: true,
      );
      await done.future;
      if (!_cancelled) meter.emitFinal();
    } catch (e, st) {
      if (!_cancelled && !ctrl.isClosed) ctrl.addError(e, st);
    } finally {
      capTimer?.cancel();
      meter.stop();
      // Not awaited: closing the client tears the socket down anyway, and
      // a cancel that settles late must not hold the progress stream open.
      unawaited(sub?.cancel());
      _abort = null;
      client.close();
      if (identical(_client, client)) _client = null;
      await ctrl.close();
    }
  }

  Future<void> _runUpload(StreamController<SpeedSample> ctrl, int total) async {
    final client = _client = _newClient();
    final meter = _Meter(ctrl, interval);
    // One random block, reused: the point is to defeat nothing but a
    // trivially compressible body, and Random() is fast enough for that.
    final block = List<int>.generate(chunkSize, (_) => _random.nextInt(256), growable: false);
    var stop = false;
    _abort = () => stop = true;

    Stream<List<int>> body() async* {
      while (!stop && !_cancelled && meter.bytes < total && meter.elapsed < uploadCap) {
        final n = min(chunkSize, total - meter.bytes);
        yield n == chunkSize ? block : block.sublist(0, n);
        // Counted once the consumer took the chunk (back-pressure keeps
        // the generator from running ahead of the socket).
        meter.bytes += n;
      }
    }

    try {
      meter.start();
      final req = _ChunkedRequest('POST', uploadUrl, body());
      // Headers arrive only after the body was consumed; a slow ack is not
      // our measurement, so it gets a short grace.
      final res = await client.send(req).timeout(uploadCap + const Duration(seconds: 5));
      await res.stream.drain<void>();
      if (!_cancelled) meter.emitFinal();
    } catch (e, st) {
      stop = true;
      if (!_cancelled && !ctrl.isClosed) ctrl.addError(e, st);
    } finally {
      meter.stop();
      _abort = null;
      client.close();
      if (identical(_client, client)) _client = null;
      await ctrl.close();
    }
  }
}

/// Periodic sampler shared by both directions.
class _Meter {
  _Meter(this.ctrl, this.interval);
  final StreamController<SpeedSample> ctrl;
  final Duration interval;
  final _sw = Stopwatch();
  Timer? _timer;
  int bytes = 0;
  int _lastBytes = 0;
  Duration _lastAt = Duration.zero;

  Duration get elapsed => _sw.elapsed;

  void start() {
    _sw.start();
    _timer = Timer.periodic(interval, (_) => _emit());
  }

  void _emit() {
    if (ctrl.isClosed) return;
    final el = _sw.elapsed;
    final dt = el - _lastAt;
    final bps = dt.inMicroseconds == 0 ? 0.0 : (bytes - _lastBytes) * 1e6 / dt.inMicroseconds;
    _lastBytes = bytes;
    _lastAt = el;
    ctrl.add(SpeedSample(bytes: bytes, elapsed: el, bps: bps));
  }

  /// One last reading so the consumer sees the final byte count.
  void emitFinal() {
    if (bytes > _lastBytes || _lastAt == Duration.zero) _emit();
  }

  void stop() {
    _timer?.cancel();
    _sw.stop();
  }
}

/// A request whose body is a lazily produced stream (so the generator can
/// stop at the time cap and count what was actually consumed).
class _ChunkedRequest extends http.BaseRequest {
  _ChunkedRequest(super.method, super.url, this._body) {
    headers['Content-Type'] = 'application/octet-stream';
  }
  final Stream<List<int>> _body;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}
