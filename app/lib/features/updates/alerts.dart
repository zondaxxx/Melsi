// The "Внимание" list: what the user should know right now, ordered by
// severity. Pure data — the widgets in alert_widgets.dart render it and
// UpdateChecker keeps the session dismissals.

import '../../core/models.dart';
import '../../state/app_state.dart';
import 'sub_health.dart';
import 'update_checker.dart';

/// Kinds in display order: faults (danger) first, then warnings, the app
/// update last — a subscription problem always matters more.
enum AlertKind {
  subExpired,
  subExhausted,
  subExpiring,
  subQuota,
  updateAvailable;

  bool get isDanger => this == subExpired || this == subExhausted;
}

class AppAlert {
  const AppAlert({
    required this.kind,
    required this.id,
    required this.textKey,
    this.args = const {},
    this.subscription,
    this.url,
  });

  final AlertKind kind;

  /// Stable id for dismissals (`sub.expired:<subId>`, `update:<tag>`).
  final String id;

  /// l10n key + placeholders of the one-line message.
  final String textKey;
  final Map<String, String> args;

  /// The subscription this is about (null for the update alert).
  final Subscription? subscription;

  /// Where tapping leads: the provider's page or the release page. null =
  /// go to the Servers tab.
  final String? url;

  bool get isDanger => kind.isDanger;
  bool get isUpdate => kind == AlertKind.updateAvailable;
}

/// Builds the alert list for [app] at `updates.now()`, dropping what the
/// user dismissed this session (see [UpdateChecker.dismissedAlerts]) and the
/// release they chose to skip. Danger first, then warnings, then the update.
List<AppAlert> alerts(AppState app, UpdateChecker updates) {
  final now = updates.now();
  final byKind = <AlertKind, List<AppAlert>>{for (final k in AlertKind.values) k: []};

  for (final s in app.subscriptions) {
    final h = health(s, now);
    if (h.isOk) continue;
    final url = s.webPageUrl ?? s.supportUrl;
    final name = {'name': s.name};
    final AppAlert a = switch (h) {
      SubscriptionHealth.expired => AppAlert(
          kind: AlertKind.subExpired,
          id: 'sub.expired:${s.id}',
          textKey: 'alert.subExpired',
          args: name,
          subscription: s,
          url: url,
        ),
      SubscriptionHealth.exhausted => AppAlert(
          kind: AlertKind.subExhausted,
          id: 'sub.exhausted:${s.id}',
          textKey: 'alert.subExhausted',
          args: name,
          subscription: s,
          url: url,
        ),
      SubscriptionHealth.expiresSoon => () {
          final days = daysLeft(s, now) ?? 0;
          return AppAlert(
            kind: AlertKind.subExpiring,
            id: 'sub.expiring:${s.id}',
            textKey: days <= 0 ? 'alert.subExpiringToday' : 'alert.subExpiring',
            args: {...name, 'n': '$days'},
            subscription: s,
            url: url,
          );
        }(),
      SubscriptionHealth.quotaLow => AppAlert(
          kind: AlertKind.subQuota,
          id: 'sub.quota:${s.id}',
          textKey: 'alert.subQuota',
          args: {...name, 'p': '${((usedFraction(s) ?? 0) * 100).floor()}'},
          subscription: s,
          url: url,
        ),
      SubscriptionHealth.ok => throw StateError('unreachable'),
    };
    byKind[a.kind]!.add(a);
  }

  final tag = updates.latestTag;
  if (tag != null && updates.available) {
    byKind[AlertKind.updateAvailable]!.add(AppAlert(
      kind: AlertKind.updateAvailable,
      id: 'update:$tag',
      textKey: 'alert.update',
      args: {'v': tag},
      url: updates.latestUrl,
    ));
  }

  // Kinds are declared in display order, so concatenating keeps subscription
  // order inside a kind (List.sort is not stable).
  return [
    for (final k in AlertKind.values)
      for (final a in byKind[k]!)
        if (!updates.dismissedAlerts.contains(a.id)) a,
  ];
}
