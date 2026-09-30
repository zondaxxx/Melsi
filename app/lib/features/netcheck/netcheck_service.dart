import '../../core/models.dart';
import '../../state/feature_service.dart';

/// Public IP / geo lookups: the real IP (measured while disconnected) and
/// the tunnel exit (measured while connected). Filled by the netcheck
/// feature; this is the wiring stub.
class NetCheckService extends FeatureService {
  NetCheckService(super.app, super.features);

  IpInfo? realIp;
  IpInfo? exitIp;
  bool checking = false;

  Future<void> refresh() async {}
}
