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
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One progress reading: total [bytes] so far, [elapsed] since the request
/// started and the instantaneous [bps] over the last interval.
class SpeedSample {
  const SpeedSample({
    required this.bytes,
    required this.elapsed,
    required this.bps,
  });

  final int bytes;
  final Duration elapsed;

  /// Bytes per second over the interval that ended with this sample.
  final double bps;

  /// Bytes per second averaged over the whole run so far.
  double get averageBps =>
      elapsed.inMicroseconds == 0 ? 0 : bytes * 1e6 / elapsed.inMicroseconds;

  @override
  String toString() =>
      'SpeedSample($bytes B, ${elapsed.inMilliseconds} ms, $bps B/s)';
}

enum SpeedFailure { timeout, server, connection, empty }

class SpeedTestException implements Exception {
  const SpeedTestException(this.failure, {this.statusCode});
  final SpeedFailure failure;
  final int? statusCode;

  static SpeedTestException from(Object error) => switch (error) {
    SpeedTestException() => error,
    TimeoutException() => const SpeedTestException(SpeedFailure.timeout),
    _ => const SpeedTestException(SpeedFailure.connection),
  };

  @override
  String toString() =>
      'Speed test ${failure.name}${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

class SpeedTest {
  SpeedTest({
    required http.Client Function() client,
    Uri? downloadUrl,
    Uri? uploadUrl,
    this.cap = const Duration(seconds: 8),
    this.uploadCap = const Duration(seconds: 6),
    this.requestTimeout = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 5),
    this.interval = const Duration(milliseconds: 250),
    Random? random,
  }) : _newClient = client,
       downloadUrl = downloadUrl ?? defaultDownloadUrl,
       uploadUrl = uploadUrl ?? defaultUploadUrl,
       _random = random ?? Random();

  static final Uri defaultDownloadUrl = Uri.parse(
    'https://speed.cloudflare.com/__down?bytes=50000000',
  );
  static final Uri defaultUploadUrl = Uri.parse(
    'https://speed.cloudflare.com/__up',
  );
  static const int chunkSize = 64 << 10;

  final http.Client Function() _newClient;
  final Uri downloadUrl;
  final Uri uploadUrl;
  final Duration cap;
  final Duration uploadCap;
  final Duration requestTimeout;
  final Duration responseTimeout;
  final Duration interval;
  final Random _random;
  _Transfer? _active;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  /// Explicit cancellation invalidates the whole run, including a pending
  /// request that has not returned headers yet.
  void cancel() {
    _cancelled = true;
    _active?.abort();
  }

  Stream<SpeedSample> download() => _stream(_download);

  Stream<SpeedSample> upload({int bytes = 5 << 20}) =>
      _stream((transfer) => _upload(transfer, bytes));

  Stream<SpeedSample> _stream(Future<void> Function(_Transfer) run) {
    late StreamController<SpeedSample> ctrl;
    _Transfer? transfer;
    ctrl = StreamController<SpeedSample>(
      onListen: () async {
        try {
          if (_cancelled) return;
          final current = transfer = _Transfer(_newClient(), ctrl, interval);
          _active = current;
          await run(current);
        } catch (error, stack) {
          if (!_cancelled && !(transfer?.aborted ?? false) && !ctrl.isClosed) {
            ctrl.addError(SpeedTestException.from(error), stack);
          }
        } finally {
          transfer?.close();
          if (identical(_active, transfer)) _active = null;
          unawaited(ctrl.close());
        }
      },
      // Cancelling a progress subscription must also stop network work. It
      // does not mark the test as user-cancelled: await-for also cancels on
      // an error, and the service still needs to report that failure.
      onCancel: () => transfer?.abort(),
    );
    return ctrl.stream;
  }

  Future<void> _download(_Transfer transfer) async {
    final request = http.Request('GET', downloadUrl)
      ..headers['Cache-Control'] = 'no-cache'
      ..headers['Accept-Encoding'] = 'identity';
    final response = await transfer.wait(
      transfer.client.send(request),
      requestTimeout,
    );
    _checkStatus(response);
    final meter = transfer.meter..start();
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final capTimer = Timer(cap, finish);
    final sub = response.stream.listen(
      (chunk) {
        if (!transfer.aborted) meter.bytes += chunk.length;
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: finish,
      cancelOnError: true,
    );
    try {
      await transfer.wait(done.future);
      if (meter.bytes == 0) throw const SpeedTestException(SpeedFailure.empty);
      meter.emitFinal();
    } finally {
      capTimer.cancel();
      // A transport whose cancel Future settles late must not hold the
      // user-facing progress stream open; close() also tears down its socket.
      unawaited(sub.cancel());
    }
  }

  Future<void> _upload(_Transfer transfer, int total) async {
    // Typed storage keeps this buffer at 64 KiB rather than one boxed int
    // per byte. Its contents remain fixed while the socket consumes it.
    final block = Uint8List(chunkSize);
    for (var i = 0; i < block.length; i++) {
      block[i] = _random.nextInt(256);
    }
    final meter = transfer.meter;
    Stream<List<int>> body() async* {
      // A transport may listen late, after timeout has already closed this
      // transfer. Do not restart its sampler or send any more bytes.
      if (transfer.closed) return;
      meter.start();
      while (!transfer.closed &&
          meter.bytes < total &&
          meter.elapsed < uploadCap) {
        final n = min(chunkSize, total - meter.bytes);
        yield n == chunkSize ? block : Uint8List.sublistView(block, 0, n);
        if (!transfer.closed) meter.bytes += n;
      }
    }

    final request = _ChunkedRequest('POST', uploadUrl, body());
    final response = await transfer.wait(
      transfer.client.send(request),
      requestTimeout + uploadCap,
    );
    _checkStatus(response);
    // A server response confirms the upload. Never report success for a
    // 403/429/5xx response or wait forever for its trailing response body.
    final done = Completer<void>();
    final sub = response.stream.listen(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await transfer.wait(done.future, responseTimeout);
    } finally {
      unawaited(sub.cancel());
    }
    if (meter.bytes == 0) throw const SpeedTestException(SpeedFailure.empty);
    meter.emitFinal();
  }

  static void _checkStatus(http.StreamedResponse response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SpeedTestException(
        SpeedFailure.server,
        statusCode: response.statusCode,
      );
    }
  }
}

class _Transfer {
  _Transfer(this.client, StreamController<SpeedSample> ctrl, Duration interval)
    : meter = _Meter(ctrl, interval);
  final http.Client client;
  final _Meter meter;
  final _aborted = Completer<void>();
  bool get aborted => _aborted.isCompleted;
  bool _closed = false;
  bool get closed => _closed;

  Future<T> wait<T>(Future<T> pending, [Duration? timeout]) {
    final result = Future.any<T>([
      pending,
      _aborted.future.then<T>((_) => throw const _AbortedTransfer()),
    ]);
    return timeout == null ? result : result.timeout(timeout);
  }

  void abort() {
    if (!aborted) _aborted.complete();
    close();
  }

  void close() {
    meter.stop();
    if (_closed) return;
    _closed = true;
    client.close();
  }
}

class _AbortedTransfer implements Exception {
  const _AbortedTransfer();
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
    final bps = dt.inMicroseconds == 0
        ? 0.0
        : (bytes - _lastBytes) * 1e6 / dt.inMicroseconds;
    _lastBytes = bytes;
    _lastAt = el;
    ctrl.add(SpeedSample(bytes: bytes, elapsed: el, bps: bps));
  }

  /// One last reading so the consumer sees the final byte count.
  void emitFinal() {
    _emit();
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
