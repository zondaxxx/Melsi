import 'dart:async';
import 'dart:io';

/// TCP connect-time to `host:port` in ms (includes DNS). null on failure.
/// This is what the UI labels "TCP ping" — it only proves the port answers.
Future<int?> tcpPing(String host, int port,
    {Duration timeout = const Duration(seconds: 3)}) async {
  if (host.isEmpty || port <= 0) return null;
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    sw.stop();
    s.destroy();
    return sw.elapsedMilliseconds.clamp(1, 99999);
  } catch (_) {
    return null;
  }
}

/// Runs [tasks] with at most [concurrency] in flight.
Future<void> runPool<T>(Iterable<T> items, int concurrency,
    Future<void> Function(T item) task) async {
  final it = items.iterator;
  Future<void> worker() async {
    while (true) {
      T item;
      if (!it.moveNext()) return;
      item = it.current;
      try {
        await task(item);
      } catch (_) {}
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
}
