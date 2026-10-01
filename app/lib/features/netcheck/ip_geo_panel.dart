// Home: «Сеть» — the real IP versus the tunnel exit, with a leak verdict.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';

/// Section under the server card. One metric-style line for the real IP;
/// a second one for the exit slides in with the session. Failure is a dash
/// and a quiet footnote, never a snackbar. Hidden when the setting is off.
class IpGeoPanel extends StatelessWidget {
  const IpGeoPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (!app.settings.ipCheck) return const SizedBox.shrink();
    final net = context.features.netcheck;
    final l = context.l;
    final c = context.c;
    final connected = app.connected;
    return ListenableBuilder(
      listenable: net,
      builder: (context, _) {
        final verdict = net.verdict;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionHeader(
            l('geo.title'),
            trailing: ToolButton(
              key: const ValueKey('geo-refresh'),
              icon: Icons.refresh_rounded,
              tooltip: l('geo.refreshCmd'),
              onTap: net.checking ? null : () => net.refresh(manual: true),
            ),
          ),
          Panel(
            padding: EdgeInsets.zero,
            clip: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _IpLine(
                label: l('geo.yours'),
                info: net.realIp,
                checking: net.checking && !net.checkingExit,
                failed: net.error && net.realIp == null,
              ),
              _SlideIn(
                visible: connected,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Hairline(),
                  _IpLine(
                    label: l('geo.exit'),
                    info: net.exitIp,
                    checking: net.checking && net.checkingExit,
                    failed: net.error && net.exitIp == null,
                  ),
                ]),
              ),
              if (verdict == LeakVerdict.danger || verdict == LeakVerdict.warning) ...[
                const Hairline(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.l, Space.s + 2, Space.l, Space.m),
                  child: Row(children: [
                    StatusDot(verdict == LeakVerdict.danger ? c.danger : c.warning, size: 6),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Text(
                        verdict == LeakVerdict.danger ? l('geo.leakDirect') : l('geo.leakMaybe'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.footnote.copyWith(
                            color: verdict == LeakVerdict.danger ? c.danger : c.warning),
                      ),
                    ),
                  ]),
                ),
              ],
            ]),
          ),
        ]);
      },
    );
  }
}

/// Overline label, then country box + mono IP + organisation on one line.
/// The IP and the organisation share one rich line so the ellipsis eats
/// the organisation first and the address last (360px phones).
class _IpLine extends StatelessWidget {
  const _IpLine({
    required this.label,
    required this.info,
    required this.checking,
    required this.failed,
  });
  final String label;
  final IpInfo? info;
  final bool checking;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final l = context.l;
    final i = info;
    final detail = i == null
        ? null
        : [i.org, i.city].whereType<String>().where((s) => s.isNotEmpty).join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Overline(label)),
          if (checking)
            const Padding(
              padding: EdgeInsets.only(left: Space.s),
              child: CupertinoActivityIndicator(radius: 6),
            ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          CountryCode(i?.countryCode),
          const SizedBox(width: Space.s),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: i?.ip ?? '—',
                  style: t.mono.copyWith(
                      fontSize: 14, color: i == null ? c.tertiaryLabel : c.label),
                ),
                if (i == null && failed)
                  TextSpan(text: '  ${l('geo.noAnswer')}', style: t.footnote)
                else if (detail != null && detail.isNotEmpty)
                  TextSpan(text: '  $detail', style: t.caption),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Reveals [child] with an 8px rise and a fade when [visible] flips on,
/// collapsing its height when it flips off. Reduced motion: fade only.
class _SlideIn extends StatefulWidget {
  const _SlideIn({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  State<_SlideIn> createState() => _SlideInState();
}

class _SlideInState extends State<_SlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: widget.visible ? 1 : 0);

  @override
  void didUpdateWidget(_SlideIn old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) {
      _c.springTo(widget.visible ? 1 : 0,
          spring: Springs.of(0.4, 1.0), reduceMotion: context.reduceMotion);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return AnimatedSize(
      duration: Duration(milliseconds: reduce ? 1 : 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: widget.visible
          ? AnimatedBuilder(
              animation: _c,
              child: widget.child,
              builder: (context, child) {
                final v = _c.value.clamp(0.0, 1.0);
                return Opacity(
                  opacity: v,
                  child: reduce
                      ? child
                      : Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child),
                );
              },
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

/// Settings › App rows: the IP-check switch.
List<Widget> ipCheckRows(BuildContext context, AppState app) {
  final l = context.l;
  return [
    SwitchRow(
      title: l('geo.setting'),
      subtitle: l('geo.settingHint'),
      value: app.settings.ipCheck,
      onChanged: (v) => app.updateSettings((s) => s.ipCheck = v, affectsConfig: false),
    ),
  ];
}
