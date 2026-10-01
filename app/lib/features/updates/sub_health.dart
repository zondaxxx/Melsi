// Subscription health, derived purely from the `subscription-userinfo`
// fields a provider sends (expiry, quota). No clock of its own: the caller
// passes `now` so tests and the alert list agree on the time.

import '../../core/models.dart';

enum SubscriptionHealth {
  ok,

  /// Expires within [kExpiringSoonDays] days.
  expiresSoon,
  expired,

  /// At least [kQuotaLowFraction] of the quota is used.
  quotaLow,
  exhausted;

  /// Expired / exhausted are faults (danger); the rest are warnings.
  bool get isDanger => this == expired || this == exhausted;
  bool get isOk => this == ok;
}

const int kExpiringSoonDays = 3;
const double kQuotaLowFraction = 0.9;

/// Whole days until expiry (negative once expired); null without an expiry.
int? daysLeft(Subscription s, DateTime now) {
  final e = s.expire;
  if (e == null) return null;
  final d = e.difference(now);
  // Truncate towards "fewer days left": 2 days 20 h is "2 days", and an
  // expiry 3 h ago is "-1", never "0".
  return d.isNegative ? -((-d).inDays + 1) : d.inDays;
}

/// Used share of the quota (upload + download over total), or null when the
/// provider reports no total.
double? usedFraction(Subscription s) {
  final total = s.total;
  if (total == null || total <= 0) return null;
  final used = (s.upload ?? 0) + (s.download ?? 0);
  return used / total;
}

/// The single most important thing to say about [s] at [now].
SubscriptionHealth health(Subscription s, DateTime now) {
  final expire = s.expire;
  if (expire != null && !expire.isAfter(now)) return SubscriptionHealth.expired;
  final used = usedFraction(s);
  if (used != null && used >= 1) return SubscriptionHealth.exhausted;
  final days = daysLeft(s, now);
  if (days != null && days <= kExpiringSoonDays) return SubscriptionHealth.expiresSoon;
  if (used != null && used >= kQuotaLowFraction) return SubscriptionHealth.quotaLow;
  return SubscriptionHealth.ok;
}
