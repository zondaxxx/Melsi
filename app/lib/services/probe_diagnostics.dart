/// Categories describe the observed error, never the availability of the
/// whole internet connection. Raw core messages stay in the diagnostic log.
enum ProbeFailure {
  dns,
  tls,
  authentication,
  refused,
  route,
  timeout,
  core,
  unknown,
}

ProbeFailure classifyProbeFailure(String? error) {
  final text = (error ?? '').toLowerCase();
  if (text.contains('no such host') ||
      text.contains('failed host lookup') ||
      text.contains('dns:') ||
      text.contains('dns lookup') ||
      text.contains('dns exchange') ||
      text.contains('name resolution')) {
    return ProbeFailure.dns;
  }
  if (text.contains('certificate') ||
      text.contains('x509') ||
      text.contains('tls handshake') ||
      text.contains('tls:') ||
      text.contains('reality verification') ||
      text.contains('handshakefailure')) {
    return ProbeFailure.tls;
  }
  if (text.contains('authentication failed') ||
      text.contains('invalid user') ||
      text.contains('invalid password')) {
    return ProbeFailure.authentication;
  }
  if (text.contains('no route to host') ||
      text.contains('network is unreachable') ||
      text.contains('network unreachable')) {
    return ProbeFailure.route;
  }
  if (text.contains('connection refused') ||
      text.contains('actively refused')) {
    return ProbeFailure.refused;
  }
  if (text.contains('timeout') ||
      text.contains('timed out') ||
      text.contains('deadline exceeded')) {
    return ProbeFailure.timeout;
  }
  return ProbeFailure.unknown;
}

String probeFailureKey(ProbeFailure failure) => 'doctor.probe.${failure.name}';
